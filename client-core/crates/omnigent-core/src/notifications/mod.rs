//! Notification scope and push-payload decisions.
//!
//! - [`route`]: the account scope, the versioned push payload route, and the dedupe ledger.
//! - [`push`]: device registration requests. A 404 is [`PushSupport::Unsupported`].
//! - [`attention`]: what to notify and when (turn end with idle settle, elicitation, runner
//!   offline, viewed-session suppression), with injected time.
//!
//! Everything is sans-IO: the host shows notifications, owns timers and permission prompts, and
//! sends the requests.

pub mod attention;
pub mod push;
pub mod route;

pub use attention::{
    AttentionNotification, AttentionTracker, ELICITATION_BODY, IDLE_BODY, IDLE_SETTLE_MS,
    ViewContext, unread_badge_ids,
};
pub use push::{
    PushCapabilities, PushError, PushRegistration, PushSupport, capabilities_request,
    capabilities_response, mutation_response, register_request, unregister_request,
};
pub use route::{
    MAX_LEDGER_ENTRIES, NotificationError, NotificationKind, NotificationLedger, NotificationRoute,
    NotificationScope, PushPresentation, foreground_presentation, is_valid_identifier,
};

#[cfg(test)]
mod tests;
