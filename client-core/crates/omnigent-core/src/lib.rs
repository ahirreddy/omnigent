//! Sans-IO Omnigent client core.
//!
//! The core never performs I/O, spawns threads, reads clocks, or depends on an async runtime: every
//! side effect goes through a host trait (see [`http::HttpTransport`]), so the same code runs under
//! Swift (`UniFFI`), the web (WASM), and plain `block_on` in tests.

#![forbid(unsafe_code)]

pub mod attachments;
pub mod auth;
mod client;
pub mod config;
pub mod creation;
pub mod decisions;
pub mod deeplink;
pub mod demo;
mod discovery;
mod error;
pub mod http;
pub mod ledger;
pub mod notifications;
pub mod read_state;
pub mod realtime;
pub mod reconcile;
pub mod reducer;
pub mod remote_browser;
pub mod schedule;
pub mod server_url;
pub mod session_attention;
pub mod session_query;
pub mod slash;
pub mod sse;
pub mod terminal;
#[cfg(test)]
pub(crate) mod testing;
pub mod workspace;
pub mod workspace_store;

pub use client::{
    ClientCore, ClientEvent, ClientListener, CoreConfig, SLICE_KEY_HEADER, SLICE_KEY_QUERY,
    SessionError, SubscriptionId, automations, browser, comments, configure, create,
    databricks_session, events, fork, inbox, items, projects, sessions, usage,
};
pub use discovery::{ServerDiscovery, discovery_from_response, manifest_request};
pub use error::CoreError;
pub use omnigent_protocol::AuthMode;
