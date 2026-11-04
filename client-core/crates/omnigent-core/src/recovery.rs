//! How a failed turn recovers (the web's error card Retry): a turn the runner survived continues
//! in place; one whose runner or terminal died resumes the session.

use crate::reducer::{Activity, ActivityKind};

/// What Retry does for a failed turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FailureRecovery {
    /// The runner is healthy and only the model call failed: ask it to continue.
    Continue,
    /// The runner or terminal went away: relaunch it (`retry_session`).
    Resume,
}

/// The text a continuation sends.
pub const CONTINUE_PROMPT: &str = "Please continue from where you left off.";

/// What Retry does for an error with `code`; `None` when retrying would not help.
#[must_use]
pub fn failure_recovery(code: &str) -> Option<FailureRecovery> {
    match code {
        "rate_limit_exceeded" | "transient_upstream_error" | "connection_error" => {
            Some(FailureRecovery::Continue)
        }
        "required_terminal_exited"
        | "terminal_launch_failed"
        | "runner_disconnected"
        | "runner_failed_to_start"
        | "runner_process_crash"
        | "runner_unavailable" => Some(FailureRecovery::Resume),
        _ => None,
    }
}

impl Activity {
    /// What Retry does for this error row; `None` for other rows and unretryable errors.
    #[must_use]
    pub fn recovery(&self) -> Option<FailureRecovery> {
        if self.kind != ActivityKind::Error {
            return None;
        }
        self.detail("code").and_then(failure_recovery)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::reducer::DetailSection;

    fn error(code: &str) -> Activity {
        Activity {
            kind: ActivityKind::Error,
            title: "Response error".into(),
            summary: String::new(),
            status: Some("failed".into()),
            details: vec![DetailSection {
                id: "code".into(),
                title: "Code".into(),
                text: code.into(),
                is_code: true,
            }],
        }
    }

    #[test]
    fn codes_map_to_continue_resume_or_nothing() {
        assert_eq!(
            error("rate_limit_exceeded").recovery(),
            Some(FailureRecovery::Continue)
        );
        assert_eq!(
            error("runner_process_crash").recovery(),
            Some(FailureRecovery::Resume)
        );
        assert_eq!(error("budget_exhausted").recovery(), None);
        let mut tool = error("rate_limit_exceeded");
        tool.kind = ActivityKind::ToolResult;
        assert_eq!(tool.recovery(), None);
    }
}
