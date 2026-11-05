//! The headline of an error row.
//!
//! The runner's own title, else a sentence for the failure code (the web's
//! `FAILURE_CODE_DESCRIPTIONS` in `components/blocks/StatusBlocks.tsx`, mirroring the server's
//! `describe_failure_code`), else a generic line.

/// The sentence for a known failure `code`, `None` for codes without one.
#[must_use]
pub fn failure_description(code: &str) -> Option<&'static str> {
    Some(match code {
        "required_terminal_exited" => {
            "The agent's terminal exited unexpectedly, so the session can't continue."
        }
        "terminal_launch_failed" => "The agent's terminal couldn't be started on the host.",
        "runner_error" => "Something went wrong setting up the turn on the host.",
        "runner_disconnected" => "The connection to the host dropped unexpectedly.",
        "runner_unavailable" => "The session's runner isn't connected to the server.",
        "connection_error" => {
            "The connection to the agent dropped mid-turn; retrying usually continues the turn."
        }
        "context_length_exceeded" => "The conversation grew past the model's context window.",
        "executor_error" => "The agent runtime hit an error while running the turn.",
        "workspace_missing" => "The session workspace no longer exists on the host.",
        "session_agent_missing" => {
            "This agent no longer exists. Fork this session into another agent to continue."
        }
        "codex_thread_reset" => {
            "Codex hit an error reloading the earlier transcript, so it started a fresh thread."
        }
        "codex_turn_error" => "Codex ran into an error during this turn.",
        "databricks_sign_in_pending" => "The agent is waiting for a Databricks sign-in.",
        "agent_startup_pending" => "The agent is still starting in the session terminal.",
        "databricks_sign_in_completed" => {
            "The Databricks sign-in completed and the agent is ready."
        }
        "codex_thread_not_started" => {
            "Codex stopped before it could start, so this turn never ran."
        }
        "native_turn_error" => "The agent ran into an error during this turn.",
        "native_prompt_not_recorded" => "Message not delivered. Try sending it again.",
        "rate_limit_exceeded" => "The model's rate limit was reached. You can retry this turn.",
        "transient_upstream_error" => {
            "The model service hit a temporary error mid-response; retrying usually continues the turn."
        }
        "budget_exhausted" => {
            "The AI gateway refused this turn because a spending budget or usage limit is exhausted. Contact an admin to raise it, or use a different budget."
        }
        "codex_compaction_model_failed" => {
            "Codex couldn't compact the conversation on the previous model, so this turn didn't run."
        }
        "codex_provider_auth_failed" => {
            "Codex couldn't get a token from the model provider's sign-in command on the host."
        }
        "client_update_required" => {
            "The agent CLI on the host is too old for the selected model. Update it on the host, then start a new session."
        }
        "host_disk_full" => "The host's disk is full, so the agent can't save the conversation.",
        _ => return None,
    })
}

/// Whether a failure with `code` reads as an account limit rather than a failure.
#[must_use]
pub fn is_neutral_failure(code: &str) -> bool {
    matches!(code, "budget_exhausted" | "codex_compaction_model_failed")
}

/// The headline of an error row.
/// - `title`: the runner's headline, when it sent one.
/// - `code`: the failure code.
/// - `is_info`: the error is an informational notice.
#[must_use]
pub fn failure_headline(title: Option<&str>, code: &str, is_info: bool) -> String {
    if let Some(title) = title.map(str::trim).filter(|title| !title.is_empty()) {
        return title.to_owned();
    }
    if let Some(description) = failure_description(code) {
        return description.to_owned();
    }
    if is_info {
        "Notice"
    } else {
        "Something went wrong"
    }
    .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_runner_title_wins_then_the_code_then_a_generic_line() {
        assert_eq!(
            failure_headline(Some("Signed in"), "rate_limit_exceeded", false),
            "Signed in"
        );
        assert_eq!(
            failure_headline(Some("  "), "rate_limit_exceeded", false),
            "The model's rate limit was reached. You can retry this turn."
        );
        assert_eq!(
            failure_headline(None, "unheard_of", false),
            "Something went wrong"
        );
        assert_eq!(failure_headline(None, "unheard_of", true), "Notice");
    }

    #[test]
    fn spent_budgets_are_neutral() {
        assert!(is_neutral_failure("budget_exhausted"));
        assert!(!is_neutral_failure("runner_unavailable"));
    }
}
