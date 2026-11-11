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

pub mod accounts;
pub mod agent_tree;
pub mod approval;
pub mod attention;
pub mod automation_triggers;
pub mod automations;
pub mod browser;
pub mod canvas;
pub mod config;
pub mod configuration;
pub mod creation;
pub mod custom_agents;
pub mod decisions;
pub mod deeplink;
pub mod errors;
pub mod events;
pub mod fork;
pub mod harness_accounts;
pub mod harness_setup;
pub mod host;
pub mod host_switch;
pub mod http;
pub mod inbox;
pub mod policy_registry;
pub mod pull_request_detail;
pub mod pull_requests;
pub mod queue;
pub mod remote_browser;
pub mod sandbox;
pub mod server_admin;
pub mod session_index;
pub mod session_tools;
pub mod sessions;
pub mod share;
pub mod sidebar;
pub mod slash;
pub mod sync;
pub mod terminal;
pub mod transcript;
pub mod workspace;

pub mod client;
pub mod connection;
mod databricks;
mod engine;
mod history_driver;
mod list_driver;
mod read_driver;
mod runtime;
mod stream_driver;
mod terminal_driver;
mod updates_driver;

#[cfg(test)]
mod api_tests;
#[cfg(test)]
mod automations_tests;
#[cfg(test)]
mod custom_agents_tests;
#[cfg(test)]
mod driver_tests;
#[cfg(test)]
mod harness_setup_tests;
#[cfg(test)]
mod inbox_tests;
#[cfg(test)]
mod pull_request_detail_tests;
#[cfg(test)]
mod read_tests;
#[cfg(test)]
mod remote_browser_tests;
#[cfg(test)]
mod sandbox_tests;
#[cfg(test)]
mod server_admin_tests;
#[cfg(test)]
mod session_tools_tests;
#[cfg(test)]
mod sidebar_tests;
#[cfg(test)]
mod slash_tests;
#[cfg(test)]
mod test_support;
#[cfg(test)]
mod upload_tests;

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
#[cfg(test)]
mod agent_tree_tests;
#[cfg(test)]
mod approval_tests;
#[cfg(test)]
mod attention_tests;
#[cfg(test)]
mod browser_tests;
#[cfg(test)]
mod canvas_tests;
#[cfg(test)]
mod config_tests;
#[cfg(test)]
mod configuration_tests;
#[cfg(test)]
mod creation_tests;
#[cfg(test)]
mod decisions_tests;
#[cfg(test)]
mod deeplink_tests;
#[cfg(test)]
mod errors_tests;
#[cfg(test)]
mod fork_tests;
#[cfg(test)]
mod host_switch_tests;
#[cfg(test)]
mod policy_registry_tests;
#[cfg(test)]
mod queue_tests;
#[cfg(test)]
mod session_index_tests;
#[cfg(test)]
mod session_intents_tests;
#[cfg(test)]
mod sessions_tests;
#[cfg(test)]
mod share_tests;
