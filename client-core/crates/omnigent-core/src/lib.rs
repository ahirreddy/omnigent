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
pub mod deeplink;
mod discovery;
mod error;
pub mod http;
pub mod ledger;
pub mod realtime;
pub mod server_url;
pub mod sse;
#[cfg(test)]
pub(crate) mod testing;

pub use client::{ClientCore, CoreConfig};
pub use discovery::{ServerDiscovery, discovery_from_response, manifest_request};
pub use error::CoreError;
pub use omnigent_protocol::AuthMode;
