//! Reconnect backoff with injected jitter.
//!
//! The policy is the one in `web/src/lib/reconnectBackoff.ts`. After `n` consecutive failed
//! attempts the cap is `min(base × 2^(n-1), max)`, and the delay is drawn uniformly from
//! `[cap/2, cap)`. The default base is 250 ms and the default max is 5 s. A connection that
//! stayed live for [`RetryConfig::healthy_after_ms`] earns an immediate reconnect and a fresh
//! ramp. The ramp also counts as healthy only after that long, so a server that accepts and
//! then drops every connection still backs off.
//!
//! `NativeLab` differs (`0.25 s × 2^(n-1)`, capped at 8 s, with no jitter; divergence D5). The
//! Rust port follows the plan.

use super::link::{Disposition, LinkError};

/// The exponential ramp.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BackoffConfig {
    /// Cap after the first failure, in ms.
    pub base_ms: u64,
    /// Largest cap, in ms.
    pub max_ms: u64,
}

impl Default for BackoffConfig {
    fn default() -> Self {
        Self {
            base_ms: 250,
            max_ms: 5_000,
        }
    }
}

impl BackoffConfig {
    /// The un-jittered cap after `failures` consecutive failures (`failures >= 1`). Zero
    /// failures yields 0.
    #[must_use]
    pub fn cap_ms(&self, failures: u32) -> u64 {
        if failures == 0 {
            return 0;
        }
        let factor = 2_u64.saturating_pow(failures - 1);
        self.base_ms.saturating_mul(factor).min(self.max_ms)
    }

    /// The jittered delay after `failures` consecutive failures: uniform in `[cap/2, cap)`, and
    /// exactly `cap/2` when `cap` is 0 or 1.
    pub fn delay_ms(&self, failures: u32, jitter: &mut impl JitterSource) -> u64 {
        let cap = self.cap_ms(failures);
        let half = cap / 2;
        let span = cap - half;
        // (sample / 2^32) × span, in integers: `span` is at most `max_ms`, so this cannot
        // overflow for any realistic cap.
        let offset = u64::from(jitter.next_u32()).saturating_mul(span) >> 32;
        half + offset
    }
}

/// A source of uniformly distributed random numbers for jitter. The host seeds it, so tests
/// can make it deterministic.
pub trait JitterSource {
    /// The next uniformly distributed 32-bit value.
    fn next_u32(&mut self) -> u32;
}

/// `SplitMix64`, a small, fast, non-cryptographic generator. It is enough to keep clients from
/// redialling in lockstep. Seed it from the platform's random source.
#[derive(Debug, Clone)]
pub struct SplitMix64 {
    state: u64,
}

impl SplitMix64 {
    /// A generator starting from `seed`.
    #[must_use]
    pub const fn new(seed: u64) -> Self {
        Self { state: seed }
    }
}

impl JitterSource for SplitMix64 {
    fn next_u32(&mut self) -> u32 {
        self.state = self.state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut mixed = self.state;
        mixed = (mixed ^ (mixed >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        mixed = (mixed ^ (mixed >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        mixed ^= mixed >> 31;
        let [b0, b1, b2, b3, ..] = mixed.to_be_bytes();
        u32::from_be_bytes([b0, b1, b2, b3])
    }
}

/// Reconnect policy shared by the SSE and WebSocket machines.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RetryConfig {
    /// The ramp for failed attempts.
    pub backoff: BackoffConfig,
    /// A connection live at least this long counts as healthy. Its loss reconnects at once and
    /// resets the ramp. The default is 5 s, `HEALTHY_CONNECTION_MS` in
    /// `web/src/lib/sessionUpdatesSocket.ts`.
    pub healthy_after_ms: u64,
    /// Consecutive 404 answers retried before giving up. A proxy serves 404 while the backend
    /// restarts. The default is 10, `MAX_TRANSIENT_404_RETRIES` in `web/src/store/chatStore.ts`.
    pub max_not_found_retries: u32,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            backoff: BackoffConfig::default(),
            healthy_after_ms: 5_000,
            max_not_found_retries: 10,
        }
    }
}

/// What to do after a connection attempt ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RetryDecision {
    /// Reconnect after `delay_ms`. `failures` is the consecutive-failure count it was drawn for
    /// (0 after a healthy connection).
    Reconnect { delay_ms: u64, failures: u32 },
    /// Do not reconnect.
    GiveUp,
}

/// Consecutive-failure bookkeeping.
#[derive(Debug, Clone)]
pub(crate) struct Retry {
    config: RetryConfig,
    failures: u32,
    not_found: u32,
}

impl Retry {
    pub(crate) const fn new(config: RetryConfig) -> Self {
        Self {
            config,
            failures: 0,
            not_found: 0,
        }
    }

    /// Forgets all failures, for a caller-initiated (re)start.
    pub(crate) const fn reset(&mut self) {
        self.failures = 0;
        self.not_found = 0;
    }

    /// A connection proved itself live (ready heartbeat or first snapshot).
    pub(crate) const fn on_live(&mut self) {
        self.not_found = 0;
    }

    /// Decides what follows the loss of an attempt. `live_for_ms` is how long it was live, or
    /// `None` when it never became live.
    pub(crate) fn after_loss(
        &mut self,
        error: &LinkError,
        live_for_ms: Option<u64>,
        jitter: &mut impl JitterSource,
    ) -> RetryDecision {
        match error.disposition() {
            Disposition::GiveUp => return RetryDecision::GiveUp,
            Disposition::RetryNotFound => {
                self.not_found = self.not_found.saturating_add(1);
                if self.not_found > self.config.max_not_found_retries {
                    return RetryDecision::GiveUp;
                }
            }
            Disposition::Retry => self.not_found = 0,
        }
        if live_for_ms.is_some_and(|live| live >= self.config.healthy_after_ms) {
            self.failures = 0;
            return RetryDecision::Reconnect {
                delay_ms: 0,
                failures: 0,
            };
        }
        self.failures = self.failures.saturating_add(1);
        RetryDecision::Reconnect {
            delay_ms: self.config.backoff.delay_ms(self.failures, jitter),
            failures: self.failures,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::realtime::test_support::FixedJitter;

    #[test]
    fn caps_double_from_250_ms_to_5_s() {
        let config = BackoffConfig::default();
        let caps: Vec<u64> = (0..=8).map(|n| config.cap_ms(n)).collect();
        assert_eq!(
            caps,
            [0, 250, 500, 1_000, 2_000, 4_000, 5_000, 5_000, 5_000]
        );
        assert_eq!(
            config.cap_ms(u32::MAX),
            5_000,
            "no overflow at absurd counts"
        );
    }

    #[test]
    fn jitter_spans_half_to_full_cap() {
        let config = BackoffConfig::default();
        assert_eq!(config.delay_ms(1, &mut FixedJitter(0)), 125);
        assert_eq!(config.delay_ms(1, &mut FixedJitter(u32::MAX)), 249);
        assert_eq!(config.delay_ms(1, &mut FixedJitter(1 << 31)), 187);
        assert_eq!(config.delay_ms(9, &mut FixedJitter(0)), 2_500);
        assert_eq!(config.delay_ms(9, &mut FixedJitter(u32::MAX)), 4_999);
    }

    #[test]
    fn split_mix_is_deterministic_and_stays_in_range() {
        let config = BackoffConfig::default();
        let mut a = SplitMix64::new(42);
        let mut b = SplitMix64::new(42);
        for failures in 1..64 {
            let delay = config.delay_ms(failures, &mut a);
            assert_eq!(delay, config.delay_ms(failures, &mut b));
            let cap = config.cap_ms(failures);
            assert!(
                (cap / 2..cap).contains(&delay),
                "{delay} outside [{}, {cap})",
                cap / 2
            );
        }
        assert_ne!(SplitMix64::new(1).next_u32(), SplitMix64::new(2).next_u32());
    }

    #[test]
    fn healthy_loss_reconnects_immediately_and_resets_the_ramp() {
        let mut retry = Retry::new(RetryConfig::default());
        let mut jitter = FixedJitter(0);
        let eof = LinkError::EndOfStream;
        assert_eq!(
            retry.after_loss(&eof, None, &mut jitter),
            RetryDecision::Reconnect {
                delay_ms: 125,
                failures: 1
            }
        );
        assert_eq!(
            retry.after_loss(&eof, Some(4_999), &mut jitter),
            RetryDecision::Reconnect {
                delay_ms: 250,
                failures: 2
            },
            "a connection live under 5 s still backs off"
        );
        assert_eq!(
            retry.after_loss(&eof, Some(5_000), &mut jitter),
            RetryDecision::Reconnect {
                delay_ms: 0,
                failures: 0
            }
        );
        assert_eq!(
            retry.after_loss(&eof, None, &mut jitter),
            RetryDecision::Reconnect {
                delay_ms: 125,
                failures: 1
            }
        );
    }

    #[test]
    fn not_found_is_retried_a_bounded_number_of_times_in_a_row() {
        let mut retry = Retry::new(RetryConfig {
            max_not_found_retries: 2,
            ..RetryConfig::default()
        });
        let mut jitter = FixedJitter(0);
        let not_found = LinkError::HttpStatus { status: 404 };
        assert!(matches!(
            retry.after_loss(&not_found, None, &mut jitter),
            RetryDecision::Reconnect { .. }
        ));
        assert!(matches!(
            retry.after_loss(&not_found, None, &mut jitter),
            RetryDecision::Reconnect { .. }
        ));
        // A different outcome in between resets the 404 run.
        retry.after_loss(&LinkError::EndOfStream, None, &mut jitter);
        assert!(matches!(
            retry.after_loss(&not_found, None, &mut jitter),
            RetryDecision::Reconnect { .. }
        ));
        assert!(matches!(
            retry.after_loss(&not_found, None, &mut jitter),
            RetryDecision::Reconnect { .. }
        ));
        assert_eq!(
            retry.after_loss(&not_found, None, &mut jitter),
            RetryDecision::GiveUp
        );
    }
}
