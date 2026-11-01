//! Session terminals: lifecycle requests, the attach stream codec, and the attach state machine.
//!
//! A session's terminals are tmux panes on the session's host, exposed as session resources.
//! Everything here is sans-IO, like the rest of the core:
//!
//! - [`rest`]: `list` / `create` / `get` / `delete` request builders and response decoders for
//!   `/v1/sessions/{id}/resources/terminals`, plus the attach upgrade request.
//! - [`resource`]: the terminal resource object and its list page.
//! - [`codec`]: the attach WebSocket frames (binary input and output, JSON resize and control
//!   frames).
//! - [`attach`]: [`TerminalAttach`], the pure attach state machine. It reuses the realtime host
//!   traits ([`crate::realtime::WebSocketTransport`], [`crate::realtime::MessageSink`],
//!   [`crate::realtime::SocketMessage::Binary`]), the shared backoff ([`crate::realtime::backoff`])
//!   and the link vocabulary ([`crate::realtime::AttemptId`], [`crate::realtime::TimerToken`],
//!   [`crate::realtime::LinkError`]).
//! - [`session`]: which terminal is the session's own harness TUI, and whether the caller may
//!   type into it.
//! - [`inventory`]: [`TerminalInventory`], the session's terminal list kept current from REST
//!   snapshots and `session.resource.*` / `session.terminal.activity` stream events.
//!
//! [`ClientCore`](crate::ClientCore) sends the REST calls on its connection, and builds the
//! attach upgrade with the connection's current bearer and org header
//! (`list_terminals`, `create_terminal`, `delete_terminal`, `terminal_attach_request`).
//!
//! The renderer never sees the socket. It hands encoded input bytes and grid sizes to the
//! machine and writes [`AttachOutput::Output`] bytes into its terminal emulator.

pub mod attach;
pub mod codec;
pub mod inventory;
pub mod resource;
pub mod rest;
pub mod session;

#[cfg(test)]
mod fixture_tests;

pub use attach::{
    AttachConfig, AttachFailure, AttachInput, AttachOutput, AttachState, ClosedReason, DropReason,
    TerminalAttach, is_transport_close,
};
pub use codec::{ClientFrame, FrameError, GridSize, MAX_CLIPBOARD_BYTES, ServerFrame};
pub use inventory::{
    ACTIVITY_WINDOW_MS, InventoryError, TerminalInventory, TerminalRow, TerminalStatus,
};
pub use resource::{AGENT_TERMINAL_IDS, TerminalPage, TerminalResource};
pub use rest::{
    AttachOptions, CreateTerminal, DeleteOutcome, ListOrder, ListTerminals, TerminalEndpoint,
    TerminalError, delete_response, list_response, resource_response, user_session_key,
};
pub use session::{
    HarnessTerminal, OWNER_LEVEL, TERMINAL_UI_LABEL, TERMINAL_UI_VALUE, attach_options, can_type,
    is_terminal_first,
};
