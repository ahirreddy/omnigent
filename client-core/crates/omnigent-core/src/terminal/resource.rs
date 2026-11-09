//! The terminal resource object and its list page.
//!
//! Ground truth is `session_resource_view_to_dict` in `omnigent/entities/session_resources.py`
//! (built from `terminal_resource_view`), served by the runner and proxied unchanged by the
//! server, which may add `metadata.direct_attach_url` for owners:
//!
//! ```json
//! {"id": "terminal_bash_s1", "object": "session.resource", "type": "terminal",
//!  "session_id": "conv_1", "name": "bash:s1", "environment": "default",
//!  "metadata": {"terminal_name": "bash", "session_key": "s1", "running": true,
//!               "tmux_socket": "/tmp/...", "tmux_target": "..."}}
//! ```
//!
//! Unknown keys are kept in [`TerminalResource::raw`]. Only `id` and `type == "terminal"` are
//! required: an older runner without `metadata` still yields a usable row whose name falls back
//! to `name`.

use serde_json::{Map, Value};

use crate::attachments::policy::is_identifier;

/// Resource ids of the agent's own terminal (the harness pane behind Chat/Terminal), as opposed
/// to user shells. Mirrors `AGENT_TERMINAL_IDS` in `web/src/hooks/useTerminals.ts`.
pub const AGENT_TERMINAL_IDS: [&str; 13] = [
    "terminal_tui_main",
    "terminal_claude_main",
    "terminal_codex_main",
    "terminal_opencode_main",
    "terminal_pi_main",
    "terminal_cursor_main",
    "terminal_kiro_main",
    "terminal_goose_main",
    "terminal_qwen_main",
    "terminal_antigravity_main",
    "terminal_kimi_main",
    "terminal_hermes_main",
    "terminal_devin_main",
];

/// Prefix every server-advertised loopback attach URL must have.
///
/// Anything else is ignored so a misbehaving server cannot steer the terminal socket at an arbitrary host (the web client's
/// `parseDirectAttachUrl` rule).
pub const DIRECT_ATTACH_PREFIX: &str = "ws://127.0.0.1:";

/// One terminal resource.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalResource {
    /// Opaque resource id used in every terminal route, for example `terminal_bash_s1`.
    pub id: String,
    /// The owning session, when the payload names one.
    pub session_id: Option<String>,
    /// The declared terminal name, for example `bash` (`metadata.terminal_name`, else the part
    /// of `name` before `:`).
    pub terminal_name: String,
    /// The session key, for example `s1` or `main` (`metadata.session_key`, else the part of
    /// `name` after `:`). Empty when neither is present.
    pub session_key: String,
    /// Whether the tmux session is running. `None` when the runner did not say.
    pub running: Option<bool>,
    /// The environment resource the terminal runs in, if reported.
    pub environment: Option<String>,
    /// A validated loopback attach URL, owner-only and only when the runner shares this machine.
    pub direct_attach_url: Option<String>,
    /// The object as sent.
    pub raw: Map<String, Value>,
}

impl TerminalResource {
    /// Decodes one resource object.
    ///
    /// # Errors
    ///
    /// A description when the value is not an object, has no identifier `id`, or has a `type`
    /// other than `terminal`.
    pub fn decode(value: Value) -> Result<Self, String> {
        let Value::Object(raw) = value else {
            return Err("terminal resource is not a JSON object".to_owned());
        };
        let id = match raw.get("id") {
            Some(Value::String(id)) if is_identifier(id) => id.clone(),
            Some(other) => return Err(format!("terminal resource id is invalid: {other}")),
            None => return Err("terminal resource has no id".to_owned()),
        };
        match raw.get("type") {
            Some(Value::String(kind)) if kind == "terminal" => {}
            None => {}
            Some(other) => return Err(format!("resource {id} has type {other}, not terminal")),
        }
        let metadata = match raw.get("metadata") {
            None | Some(Value::Null) => None,
            Some(Value::Object(metadata)) => Some(metadata),
            Some(other) => return Err(format!("resource {id} metadata is not an object: {other}")),
        };
        let meta_string = |key: &str| {
            metadata
                .and_then(|metadata| metadata.get(key))
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        let name = raw.get("name").and_then(Value::as_str).unwrap_or_default();
        let (name_terminal, name_key) = name.split_once(':').unwrap_or((name, ""));
        let terminal_name = meta_string("terminal_name").unwrap_or_else(|| {
            if name_terminal.is_empty() {
                id.clone()
            } else {
                name_terminal.to_owned()
            }
        });
        let session_key = meta_string("session_key").unwrap_or_else(|| name_key.to_owned());
        let running = match metadata.and_then(|metadata| metadata.get("running")) {
            None | Some(Value::Null) => None,
            Some(Value::Bool(running)) => Some(*running),
            Some(other) => return Err(format!("resource {id} running is not a bool: {other}")),
        };
        let direct_attach_url =
            meta_string("direct_attach_url").filter(|url| url.starts_with(DIRECT_ATTACH_PREFIX));
        Ok(Self {
            session_id: raw
                .get("session_id")
                .and_then(Value::as_str)
                .map(str::to_owned),
            environment: raw
                .get("environment")
                .and_then(Value::as_str)
                .map(str::to_owned),
            id,
            terminal_name,
            session_key,
            running,
            direct_attach_url,
            raw,
        })
    }

    /// Whether this is the agent's own terminal rather than a user shell.
    #[must_use]
    pub fn is_agent_terminal(&self) -> bool {
        AGENT_TERMINAL_IDS.contains(&self.id.as_str())
    }

    /// The display label, `bash · s1`, or just the name without a session key.
    #[must_use]
    pub fn display_label(&self) -> String {
        if self.session_key.is_empty() {
            self.terminal_name.clone()
        } else {
            format!("{} · {}", self.terminal_name, self.session_key)
        }
    }
}

/// One page of `GET /v1/sessions/{id}/resources/terminals`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalPage {
    /// The terminals, in the requested order.
    pub terminals: Vec<TerminalResource>,
    /// The cursor for the next page, when there is one.
    pub last_id: Option<String>,
    /// Whether more rows follow.
    pub has_more: bool,
}

impl TerminalPage {
    /// Decodes a `PaginatedList` body.
    ///
    /// # Errors
    ///
    /// A description when the body has no `data` array, or an element is not a terminal
    /// resource (non-terminal rows are an error here because this route is typed).
    pub fn decode(value: Value) -> Result<Self, String> {
        let Value::Object(mut object) = value else {
            return Err("terminal list is not a JSON object".to_owned());
        };
        let Some(Value::Array(rows)) = object.remove("data") else {
            return Err("terminal list has no data array".to_owned());
        };
        let terminals = rows
            .into_iter()
            .enumerate()
            .map(|(index, row)| {
                TerminalResource::decode(row).map_err(|message| format!("row {index}: {message}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let has_more = match object.get("has_more") {
            None | Some(Value::Null) => false,
            Some(Value::Bool(has_more)) => *has_more,
            Some(other) => return Err(format!("has_more is not a bool: {other}")),
        };
        let last_id = object
            .get("last_id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned);
        if has_more && last_id.is_none() {
            return Err("terminal list claims more rows without a last_id cursor".to_owned());
        }
        Ok(Self {
            terminals,
            last_id,
            has_more,
        })
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn a_terminal_list_must_be_an_object_and_has_more_a_boolean() {
        assert_eq!(
            TerminalPage::decode(json!([])).map(|page| page.has_more),
            Err("terminal list is not a JSON object".to_owned())
        );
        assert!(
            !TerminalPage::decode(json!({"data": [], "has_more": null}))
                .unwrap()
                .has_more
        );
        assert!(TerminalPage::decode(json!({"data": [], "has_more": "yes"})).is_err());
    }

    #[test]
    fn decodes_the_runner_shape_and_keeps_raw() {
        let resource = TerminalResource::decode(json!({
            "id": "terminal_bash_s1", "object": "session.resource", "type": "terminal",
            "session_id": "conv_1", "name": "bash:s1", "environment": "default",
            "metadata": {"terminal_name": "bash", "session_key": "s1", "running": true,
                          "tmux_socket": "/tmp/x", "tmux_target": "t", "future": 1}
        }))
        .unwrap();
        assert_eq!(resource.id, "terminal_bash_s1");
        assert_eq!(resource.terminal_name, "bash");
        assert_eq!(resource.session_key, "s1");
        assert_eq!(resource.running, Some(true));
        assert_eq!(resource.environment.as_deref(), Some("default"));
        assert_eq!(resource.display_label(), "bash · s1");
        assert!(!resource.is_agent_terminal());
        assert_eq!(resource.raw["metadata"]["future"], 1);
    }

    #[test]
    fn falls_back_to_name_and_flags_agent_terminals() {
        let resource =
            TerminalResource::decode(json!({"id": "terminal_claude_main", "name": "claude:main"}))
                .unwrap();
        assert_eq!(resource.terminal_name, "claude");
        assert_eq!(resource.session_key, "main");
        assert_eq!(resource.running, None);
        assert!(resource.is_agent_terminal());
        let bare = TerminalResource::decode(json!({"id": "terminal_x"})).unwrap();
        assert_eq!(bare.display_label(), "terminal_x");
    }

    #[test]
    fn only_loopback_direct_attach_urls_are_kept() {
        let decode = |url: &str| {
            TerminalResource::decode(json!({"id": "t1", "metadata": {"direct_attach_url": url}}))
                .unwrap()
                .direct_attach_url
        };
        assert_eq!(
            decode("ws://127.0.0.1:5000/v1/x?token=a").as_deref(),
            Some("ws://127.0.0.1:5000/v1/x?token=a")
        );
        assert_eq!(decode("wss://evil.example/x"), None);
        assert_eq!(decode("ws://127.0.0.1.evil.example/x"), None);
    }

    #[test]
    fn rejects_wrong_types_and_ids() {
        for value in [
            json!([]),
            json!({"type": "terminal"}),
            json!({"id": "a/b"}),
            json!({"id": "t", "type": "environment"}),
            json!({"id": "t", "metadata": []}),
            json!({"id": "t", "metadata": {"running": "yes"}}),
        ] {
            assert!(TerminalResource::decode(value.clone()).is_err(), "{value}");
        }
    }

    #[test]
    fn pages_validate_cursors() {
        let page = TerminalPage::decode(json!({
            "object": "list", "data": [{"id": "t1"}], "first_id": "t1", "last_id": "t1",
            "has_more": false
        }))
        .unwrap();
        assert_eq!(page.terminals.len(), 1);
        assert!(!page.has_more);
        assert!(TerminalPage::decode(json!({"data": [], "has_more": true})).is_err());
        assert!(TerminalPage::decode(json!({"data": [{"id": "t", "type": "file"}]})).is_err());
        assert!(TerminalPage::decode(json!({})).is_err());
    }
}
