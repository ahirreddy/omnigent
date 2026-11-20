//! Sans-IO Omnigent client core.
//!
//! The core never performs I/O, spawns threads, reads clocks, or depends on an async runtime: every
//! side effect goes through a host trait (see [`http::HttpTransport`]), so the same code runs under
//! Swift (`UniFFI`), the web (WASM), and plain `block_on` in tests.

#![forbid(unsafe_code)]

pub mod attachments;
pub mod auth;
pub mod automation_triggers;
pub mod canvas;
mod client;
pub mod config;
pub mod creation;
pub mod custom_agents;
pub mod decisions;
pub mod deeplink;
pub mod demo;
mod discovery;
mod error;
pub mod failure_copy;
pub mod harness_accounts;
pub mod harness_setup;
pub mod http;
pub mod intents;
pub mod ledger;
pub mod markdown_preview;
pub mod mentions;
pub mod message_cache;
pub mod nested_creation;
pub mod notifications;
pub mod project_board;
pub mod read_state;
pub mod realtime;
pub mod reconcile;
pub mod recovery;
pub mod reducer;
pub mod remote_browser;
pub mod reply_draft;
pub mod sandbox;
pub mod sandbox_state;
pub mod schedule;
pub mod server_url;
pub mod session_attention;
pub mod session_environment;
pub mod session_families;
pub mod session_index;
pub mod session_journal;
pub mod session_query;
pub mod slash;
pub mod sse;
pub mod terminal;
#[cfg(test)]
pub(crate) mod testing;
pub mod workflows;
pub mod workspace;
pub mod workspace_store;

pub use client::{
    ClientCore, ClientEvent, ClientListener, CoreConfig, SLICE_KEY_HEADER, SLICE_KEY_QUERY,
    SessionError, SubscriptionId, agent_info, agent_tree, automations, browser, comments,
    configure, create, databricks_session, events, execution_logs, fork, harness_inventory,
    host_switch, inbox, inbox_items, items, mcp_tools, pdf_comments, pin_order, policy_registry,
    project_repository, project_settings, projects, pull_request_detail, pull_request_edits,
    pull_requests, rewind, server_admin, session_mcp, session_search, session_tools, sessions,
    share, usage, user_settings,
};
pub use discovery::{ServerDiscovery, discovery_from_response, manifest_request};
pub use error::CoreError;
pub use omnigent_protocol::AuthMode;
