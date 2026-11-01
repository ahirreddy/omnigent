//! `UniFFI` surface of the Omnigent client core.
//!
//! - [`host`]: the traits Swift implements (transports, clock, scheduler, secure storage,
//!   entropy, settings and managed preferences) and the sinks Swift calls back into.
//! - [`client::ClientCore`]: one object per server connection. It owns the sign-in flows, runs
//!   the session-stream and session-updates state machines through the host transports, keeps a
//!   `ConversationSync` per open session, and reports granular [`events::CoreEvent`]s to a
//!   [`events::CoreListener`].
//! - The other modules mirror core data types as records and enums, with `From` conversions.
//!
//! Doc comments on exported items are copied into the generated Swift.

#![allow(
    clippy::multiple_crate_versions,
    reason = "uniffi 0.32 depends on both syn 2 and syn 3; not fixable from this workspace"
)]
#![allow(
    clippy::needless_pass_by_value,
    reason = "UniFFI hands exported functions owned values"
)]
#![allow(
    clippy::must_use_candidate,
    reason = "exported to Swift, where `#[must_use]` has no effect"
)]
#![allow(
    clippy::struct_excessive_bools,
    reason = "records mirror the core's flags one to one"
)]
#![allow(
    clippy::redundant_pub_crate,
    reason = "crate-internal items of private modules; `pub` would trip rustc's unreachable_pub"
)]

pub mod config;
pub mod decisions;
pub mod deeplink;
pub mod errors;
pub mod events;
pub mod host;
pub mod http;
pub mod sessions;
pub mod sync;
pub mod transcript;

pub mod client;
pub mod connection;
mod engine;
mod runtime;
mod stream_driver;
mod updates_driver;

#[cfg(test)]
mod driver_tests;
#[cfg(test)]
mod test_support;

uniffi::setup_scaffolding!();

/// The Rust core's crate version.
#[must_use]
#[uniffi::export]
pub fn core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn version_is_the_crate_version() {
        assert_eq!(super::core_version(), env!("CARGO_PKG_VERSION"));
    }
}
