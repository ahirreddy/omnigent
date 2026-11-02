//! Input validation and coalescing.
//!
//! Mouse moves and wheel events are coalesced: at most one goes out per
//! [`InputCoalescer::interval_ms`]; the latest move wins and wheel deltas are summed. Any other
//! input first flushes the pending move or wheel, so the host sees events in the order the user
//! made them and never loses a `down`, `up`, key or IME event.

use omnigent_protocol::remote_browser::{
    EditCommand, EditOp, ImeEvent, ImeOp, KeyEvent, MAX_PASTE_BYTES, MouseEvent, MouseKind,
    NavCommand, NavOp, TouchEvent, Viewport, modifiers,
};

/// Default coalescing interval, about one 60 Hz display frame.
pub const DEFAULT_INTERVAL_MS: u64 = 16;
/// Smallest viewport edge a `resize` may ask for.
pub const MIN_VIEWPORT_EDGE: u32 = 200;
/// Largest viewport edge a `resize` may ask for.
pub const MAX_VIEWPORT_EDGE: u32 = 3840;
/// Smallest device pixel ratio.
pub const MIN_DPR: f64 = 1.0;
/// Largest device pixel ratio.
pub const MAX_DPR: f64 = 3.0;
/// Longest URL a `navigate` may carry.
pub const MAX_URL_LEN: usize = 8 * 1024;

/// Why an input cannot be sent.
#[derive(Debug, Clone, PartialEq, thiserror::Error)]
pub enum InputError {
    /// A coordinate or delta is NaN or infinite.
    #[error("{field} must be a finite number")]
    NotFinite {
        /// The field.
        field: &'static str,
    },
    /// `down` or `up` without a button, or a click count outside 1–3.
    #[error("mouse {kind} needs a button and a click count of 1 to 3")]
    MissingButton {
        /// The event kind.
        kind: String,
    },
    /// Modifier bits the protocol does not define.
    #[error("modifier bits {bits:#x} are not defined")]
    UnknownModifiers {
        /// The undefined bits.
        bits: u32,
    },
    /// A `char` event without text.
    #[error("a char key event needs text")]
    MissingText,
    /// An IME selection or replacement whose end precedes its start.
    #[error("the IME {field} range ends before it starts")]
    BadRange {
        /// The field.
        field: &'static str,
    },
    /// `navigate` without a URL, or with an unusable one.
    #[error("navigate needs an http(s) or about: URL of at most 8 KiB, not {url:?}")]
    BadUrl {
        /// The URL given.
        url: Option<String>,
    },
    /// `paste` without text, or with more than 512 KiB.
    #[error("paste needs text of at most 512 KiB, not {bytes} bytes")]
    BadPaste {
        /// The text's UTF-8 length (0 when absent).
        bytes: usize,
    },
    /// Touch pressure outside 0–1 or a negative radius.
    #[error("touch {field} is out of range")]
    BadTouch {
        /// The field.
        field: &'static str,
    },
    /// A viewport outside 200–3840 px or DPR 1–3.
    #[error("viewport {w}x{h} at DPR {dpr} is outside 200-3840 px and DPR 1-3")]
    BadViewport {
        /// Width.
        w: u32,
        /// Height.
        h: u32,
        /// Device pixel ratio.
        dpr: f64,
    },
}

const fn finite(value: f64, field: &'static str) -> Result<(), InputError> {
    if value.is_finite() {
        Ok(())
    } else {
        Err(InputError::NotFinite { field })
    }
}

const fn known_modifiers(bits: u32) -> Result<(), InputError> {
    let unknown = bits & !modifiers::ALL;
    if unknown == 0 {
        Ok(())
    } else {
        Err(InputError::UnknownModifiers { bits: unknown })
    }
}

/// Checks a mouse event against the protocol.
///
/// # Errors
///
/// [`InputError`].
pub fn validate_mouse(event: &MouseEvent) -> Result<(), InputError> {
    finite(event.x, "x")?;
    finite(event.y, "y")?;
    finite(event.dx.unwrap_or_default(), "dx")?;
    finite(event.dy.unwrap_or_default(), "dy")?;
    known_modifiers(event.modifiers)?;
    if matches!(event.kind, MouseKind::Down | MouseKind::Up)
        && (event.button.is_none() || !matches!(event.clicks, Some(1..=3)))
    {
        return Err(InputError::MissingButton {
            kind: event.kind.to_string(),
        });
    }
    Ok(())
}

/// Checks a key event against the protocol.
///
/// # Errors
///
/// [`InputError`].
pub fn validate_key(event: &KeyEvent) -> Result<(), InputError> {
    known_modifiers(event.modifiers)?;
    if event.kind == omnigent_protocol::remote_browser::KeyKind::Char
        && event.text.as_deref().is_none_or(str::is_empty)
    {
        return Err(InputError::MissingText);
    }
    Ok(())
}

/// Checks an IME event against the protocol.
///
/// # Errors
///
/// [`InputError::BadRange`].
pub fn validate_ime(event: &ImeEvent) -> Result<(), InputError> {
    for (range, field) in [
        (event.selection, "selection"),
        (event.replacement, "replacement"),
    ] {
        if range.is_some_and(|range| range.end < range.start) {
            return Err(InputError::BadRange { field });
        }
    }
    if matches!(event.op, ImeOp::SetComposition | ImeOp::Commit) && event.text.is_none() {
        return Err(InputError::MissingText);
    }
    Ok(())
}

/// Checks a navigation command.
///
/// # Errors
///
/// [`InputError::BadUrl`] for `navigate` without a usable URL.
pub fn validate_nav(command: &NavCommand) -> Result<(), InputError> {
    if command.op != NavOp::Navigate {
        return Ok(());
    }
    let usable = command.url.as_deref().is_some_and(|url| {
        url.len() <= MAX_URL_LEN
            && !url.chars().any(char::is_control)
            && url::Url::parse(url)
                .is_ok_and(|parsed| matches!(parsed.scheme(), "http" | "https" | "about"))
    });
    if usable {
        Ok(())
    } else {
        Err(InputError::BadUrl {
            url: command.url.clone(),
        })
    }
}

/// Checks an `edit` command (v1.1).
///
/// # Errors
///
/// [`InputError::BadPaste`] for a paste without text or with more than 512 KiB.
pub fn validate_edit(command: &EditCommand) -> Result<(), InputError> {
    if command.op != EditOp::Paste {
        return Ok(());
    }
    let bytes = command.text.as_deref().map_or(0, str::len);
    if command.text.is_some() && bytes <= MAX_PASTE_BYTES {
        Ok(())
    } else {
        Err(InputError::BadPaste { bytes })
    }
}

/// Checks a `touch` event (v1.1).
///
/// # Errors
///
/// [`InputError::NotFinite`], [`InputError::BadTouch`] or [`InputError::UnknownModifiers`].
pub fn validate_touch(event: &TouchEvent) -> Result<(), InputError> {
    finite(event.x, "x")?;
    finite(event.y, "y")?;
    known_modifiers(event.modifiers)?;
    if event
        .pressure
        .is_some_and(|pressure| !(0.0..=1.0).contains(&pressure))
    {
        return Err(InputError::BadTouch { field: "pressure" });
    }
    if event
        .radius
        .is_some_and(|radius| !radius.is_finite() || radius < 0.0)
    {
        return Err(InputError::BadTouch { field: "radius" });
    }
    Ok(())
}

/// Checks a `resize` request.
///
/// # Errors
///
/// [`InputError::BadViewport`].
pub fn validate_viewport(viewport: &Viewport) -> Result<(), InputError> {
    let edge = MIN_VIEWPORT_EDGE..=MAX_VIEWPORT_EDGE;
    if edge.contains(&viewport.w)
        && edge.contains(&viewport.h)
        && (MIN_DPR..=MAX_DPR).contains(&viewport.dpr)
    {
        Ok(())
    } else {
        Err(InputError::BadViewport {
            w: viewport.w,
            h: viewport.h,
            dpr: viewport.dpr,
        })
    }
}

/// The result of feeding the coalescer.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Coalesced {
    /// Mouse events to send now, in order.
    pub send: Vec<MouseEvent>,
    /// Arm the flush timer for this many ms (no timer is armed already).
    pub arm_timer_ms: Option<u64>,
}

/// Coalesces mouse moves and wheel events. Pure: the caller owns the timer.
#[derive(Debug, Clone)]
pub struct InputCoalescer {
    interval_ms: u64,
    pending: Option<MouseEvent>,
    last_sent_ms: Option<u64>,
    timer_armed: bool,
}

const fn coalescible(kind: &MouseKind) -> bool {
    matches!(kind, MouseKind::Move | MouseKind::Wheel)
}

impl InputCoalescer {
    /// A coalescer sending at most one move or wheel per `interval_ms`.
    #[must_use]
    pub const fn new(interval_ms: u64) -> Self {
        Self {
            interval_ms,
            pending: None,
            last_sent_ms: None,
            timer_armed: false,
        }
    }

    /// The coalescing interval.
    #[must_use]
    pub const fn interval_ms(&self) -> u64 {
        self.interval_ms
    }

    /// Feeds one mouse event at `now_ms`.
    pub fn mouse(&mut self, now_ms: u64, event: MouseEvent) -> Coalesced {
        let mut out = Coalesced::default();
        if !coalescible(&event.kind) {
            out.send.extend(self.pending.take());
            out.send.push(event);
            return out;
        }
        if let Some(pending) = self.pending.take() {
            match merge(pending, event) {
                Merge::Merged(merged) => self.pending = Some(merged),
                Merge::Separate(previous, next) => {
                    out.send.push(previous);
                    self.last_sent_ms = Some(now_ms);
                    self.pending = Some(next);
                }
            }
        } else if self
            .last_sent_ms
            .is_none_or(|last| now_ms.saturating_sub(last) >= self.interval_ms)
        {
            self.last_sent_ms = Some(now_ms);
            out.send.push(event);
            return out;
        } else {
            self.pending = Some(event);
        }
        if !self.timer_armed {
            self.timer_armed = true;
            let since = self
                .last_sent_ms
                .map_or(0, |last| now_ms.saturating_sub(last));
            out.arm_timer_ms = Some(self.interval_ms.saturating_sub(since).max(1));
        }
        out
    }

    /// Something other than mouse input is about to go out: the pending move or wheel first.
    pub fn flush(&mut self, now_ms: u64) -> Option<MouseEvent> {
        let pending = self.pending.take()?;
        self.last_sent_ms = Some(now_ms);
        Some(pending)
    }

    /// The flush timer fired.
    pub fn timer_fired(&mut self, now_ms: u64) -> Option<MouseEvent> {
        self.timer_armed = false;
        self.flush(now_ms)
    }

    /// Drops pending input (the connection ended).
    pub fn reset(&mut self) {
        self.pending = None;
        self.last_sent_ms = None;
        self.timer_armed = false;
    }
}

enum Merge {
    Merged(MouseEvent),
    Separate(MouseEvent, MouseEvent),
}

/// Merges `next` into `pending` when both are the same coalescible kind with the same
/// modifiers; otherwise returns both.
fn merge(pending: MouseEvent, next: MouseEvent) -> Merge {
    if pending.kind != next.kind || pending.modifiers != next.modifiers {
        return Merge::Separate(pending, next);
    }
    if next.kind == MouseKind::Wheel {
        let sum = |a: Option<f64>, b: Option<f64>| match (a, b) {
            (None, None) => None,
            (a, b) => Some(a.unwrap_or_default() + b.unwrap_or_default()),
        };
        return Merge::Merged(MouseEvent {
            dx: sum(pending.dx, next.dx),
            dy: sum(pending.dy, next.dy),
            ..next
        });
    }
    Merge::Merged(next)
}

#[cfg(test)]
mod tests {
    use omnigent_protocol::remote_browser::{KeyKind, MouseButton, TextRange};

    use super::*;

    fn mouse(kind: MouseKind, x: f64) -> MouseEvent {
        MouseEvent {
            kind,
            x,
            y: 0.0,
            button: None,
            clicks: None,
            modifiers: 0,
            dx: None,
            dy: None,
        }
    }

    fn wheel(dy: f64) -> MouseEvent {
        MouseEvent {
            dy: Some(dy),
            dx: Some(0.0),
            ..mouse(MouseKind::Wheel, 5.0)
        }
    }

    #[test]
    fn first_move_goes_out_and_later_ones_collapse_until_the_timer() {
        let mut coalescer = InputCoalescer::new(16);
        let first = coalescer.mouse(100, mouse(MouseKind::Move, 1.0));
        assert_eq!(first.send.len(), 1);
        assert_eq!(first.arm_timer_ms, None);
        let second = coalescer.mouse(104, mouse(MouseKind::Move, 2.0));
        assert_eq!(second.send, []);
        assert_eq!(second.arm_timer_ms, Some(12));
        let third = coalescer.mouse(108, mouse(MouseKind::Move, 3.0));
        assert_eq!(third, Coalesced::default(), "no second timer");
        let flushed = coalescer.timer_fired(116).unwrap();
        assert!((flushed.x - 3.0).abs() < f64::EPSILON, "latest move wins");
        assert!(coalescer.timer_fired(132).is_none());
        let late = coalescer.mouse(140, mouse(MouseKind::Move, 4.0));
        assert_eq!(late.send.len(), 1, "a quiet interval sends at once");
    }

    #[test]
    fn wheel_deltas_sum_and_discrete_events_flush_first() {
        let mut coalescer = InputCoalescer::new(16);
        coalescer.mouse(0, wheel(10.0));
        coalescer.mouse(2, wheel(15.0));
        coalescer.mouse(4, wheel(-5.0));
        let mut down = mouse(MouseKind::Down, 5.0);
        down.button = Some(MouseButton::Left);
        down.clicks = Some(1);
        let out = coalescer.mouse(6, down.clone());
        assert_eq!(out.send.len(), 2);
        assert_eq!(out.send[0].dy, Some(10.0));
        assert_eq!(out.send[1], down);
        assert!(coalescer.timer_fired(16).is_none());
    }

    #[test]
    fn a_move_after_a_wheel_sends_the_wheel_first() {
        let mut coalescer = InputCoalescer::new(16);
        coalescer.mouse(0, wheel(1.0));
        coalescer.mouse(1, wheel(2.0));
        let out = coalescer.mouse(2, mouse(MouseKind::Move, 9.0));
        assert_eq!(out.send.len(), 1);
        assert_eq!(out.send[0].kind, MouseKind::Wheel);
        assert_eq!(out.send[0].dy, Some(2.0));
        assert_eq!(coalescer.flush(3).unwrap().kind, MouseKind::Move);
    }

    #[test]
    fn validation_rejects_what_the_host_would_refuse() {
        let mut down = mouse(MouseKind::Down, 1.0);
        assert!(validate_mouse(&down).is_err());
        down.button = Some(MouseButton::Right);
        down.clicks = Some(1);
        assert_eq!(validate_mouse(&down), Ok(()));
        down.modifiers = 1 << 20;
        assert!(matches!(
            validate_mouse(&down),
            Err(InputError::UnknownModifiers { .. })
        ));
        assert!(validate_mouse(&mouse(MouseKind::Move, f64::NAN)).is_err());
        let char_event = KeyEvent {
            kind: KeyKind::Char,
            code: "KeyA".into(),
            key: "a".into(),
            text: None,
            modifiers: 0,
            repeat: false,
        };
        assert_eq!(validate_key(&char_event), Err(InputError::MissingText));
        let ime = ImeEvent {
            op: ImeOp::SetComposition,
            text: Some("a".into()),
            selection: Some(TextRange { start: 2, end: 1 }),
            replacement: None,
        };
        assert!(validate_ime(&ime).is_err());
        let navigate = |url: &str| NavCommand {
            op: NavOp::Navigate,
            url: Some(url.into()),
        };
        assert!(validate_nav(&navigate("https://example.com")).is_ok());
        assert!(validate_nav(&navigate("javascript:alert(1)")).is_err());
        assert!(
            validate_nav(&NavCommand {
                op: NavOp::Navigate,
                url: None
            })
            .is_err()
        );
        assert!(
            validate_viewport(&Viewport {
                w: 1280,
                h: 800,
                dpr: 2.0
            })
            .is_ok()
        );
        assert!(
            validate_viewport(&Viewport {
                w: 100,
                h: 800,
                dpr: 1.0
            })
            .is_err()
        );
    }
}
