//! Decision (elicitation) cards: elicitation schema to typed form to resolve body.
//!
//! - [`Decision::from_request`] turns a wire [`ElicitationRequest`] into a card: a binary
//!   approval (with any permission options the request advertises), a single-field choice, a
//!   typed [`DecisionForm`], or an [`UnsupportedReason`]. Anything it cannot render exactly fails
//!   closed; it never becomes a binary approval.
//! - [`resolve`]: a [`DecisionResponse`] is checked against the card and becomes the MCP
//!   `ElicitationResult` body, and the request the host sends.
//! - [`ledger`]: the pending cards one session shows, with exact-id resolution and tombstones so
//!   a resolved card can never come back from a replay or a stale snapshot.
//!
//! Port of `NativeLab`'s `DecisionForm.swift`, `ElicitationWire` (`LocalServerLiveModels.swift`)
//! and the resolve paths of `LocalServerSessionClient` and `DemoSessionClient`, plus the web
//! `ApprovalCard` permission variants (Codex persistence, Antigravity, auto mode, directories).

mod changes;
pub mod form;
pub mod ledger;
mod partial_json;
pub mod resolve;

use omnigent_protocol::{ElicitationMode, ElicitationRequest};
use serde_json::{Map, Value};
use url::Url;

pub use changes::{FileChange, FileChangeKind};
pub use form::{
    AnswerError, DecisionForm, FieldKind, FormError, FormField, FormOption, FormProblem,
};
pub use ledger::{
    DecisionEntry, DecisionEventOutcome, DecisionState, MAX_RETIRED_IDS, RequestOutcome,
    ResolvedOutcome, SessionDecisions,
};
pub use resolve::{
    DecisionError, DecisionResponse, ResolveAcknowledgement, ResolveError, ResolveRequest,
    ResolveRoute, resolve_response,
};

const NEEDS_WEB_SCHEMA: &str = "This form uses a schema that needs the web app.";
const AGY_PERMISSION_PHASE: &str = "agy_permission";
const ASK_USER_QUESTION_CALL: &str = "AskUserQuestion(";
const PRE_TOOL_USE_PHASE: &str = "pre_tool_use";
/// Native permission hooks whose bridge hands a decline's `content.feedback` to the agent as the
/// denial reason (the server's `PermissionRequest` hook route for Claude and Devin). Other
/// harnesses drop it, so they are not offered feedback.
const FEEDBACK_POLICIES: [&str; 2] = ["claude_native_permission", "devin_native_permission"];

/// What a card asks for.
#[derive(Debug, Clone, PartialEq)]
pub enum DecisionKind {
    /// Approve or decline, plus whatever [`PermissionOptions`] the request advertises.
    Approval,
    /// One answer from `options`, posted under `answer_key` (a single-field enum schema).
    Choice {
        /// The `content` key.
        answer_key: String,
        /// The offered answers, in schema order.
        options: Vec<String>,
    },
    /// A typed multi-field form or an `AskUserQuestion` form.
    Form(DecisionForm),
    /// Cannot be answered in the native app.
    Unsupported {
        /// Why.
        reason: UnsupportedReason,
        /// A safe `http(s)` confirmation page the user may open explicitly. Never opened
        /// automatically.
        external_url: Option<String>,
    },
}

/// Why a card cannot be answered natively. The display text is user-facing.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UnsupportedReason {
    /// `requestedSchema` is not an object.
    #[error("{NEEDS_WEB_SCHEMA}")]
    NonObjectSchema,
    /// The schema cannot become a native form.
    #[error("{NEEDS_WEB_SCHEMA}")]
    Schema(FormError),
    /// The `AskUserQuestion` payload cannot become a native form.
    #[error("This structured question needs the web app's question form.")]
    Question(FormError),
    /// URL mode with a safe confirmation page: complete it there.
    #[error(
        "Complete this request on its confirmation page. The session will update when the server receives your response."
    )]
    ExternalConfirmation,
    /// A confirmation address that is not a credential-free `http(s)` URL.
    #[error(
        "This request uses a confirmation address that cannot be opened safely here. Continue in the web app."
    )]
    UnsafeConfirmationUrl,
    /// URL mode without a confirmation address.
    #[error(
        "The server did not provide a confirmation address. Continue this request in the web app."
    )]
    MissingConfirmationUrl,
    /// A `mode` this client does not know.
    #[error("This request type is not supported in the native app yet.")]
    UnknownMode {
        /// The mode as sent.
        mode: String,
    },
}

/// Codex and Antigravity persistence scopes (`_meta.persist` on accept).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum PersistMode {
    /// `session`: for the rest of this session.
    Session,
    /// `always`: persistently.
    Always,
}

impl PersistMode {
    /// The wire value.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Session => "session",
            Self::Always => "always",
        }
    }

    fn parse(value: &Value) -> Option<Self> {
        match value.as_str() {
            Some("session") => Some(Self::Session),
            Some("always") => Some(Self::Always),
            _ => None,
        }
    }
}

/// `params.remember_scope`: Claude's "don't ask again" rule scope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RememberScope {
    /// The gated tool.
    pub tool: String,
    /// The `WebFetch` domain, when present.
    pub host: Option<String>,
}

impl RememberScope {
    /// The host when present, else the tool.
    #[must_use]
    pub fn label(&self) -> &str {
        self.host.as_deref().unwrap_or(&self.tool)
    }
}

/// A Codex command approval (`params.command` and friends).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandApproval {
    /// The command line.
    pub command: String,
    /// Working directory.
    pub cwd: Option<String>,
    /// Why the agent wants to run it.
    pub reason: Option<String>,
}

/// Antigravity permission details (`phase == "agy_permission"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AntigravityPermission {
    /// What Antigravity says it wants to do.
    pub action_description: Option<String>,
    /// The command prefix Antigravity offers to always allow. Only when present may the card
    /// offer the session and always persistence choices.
    pub always_allow_pattern: Option<String>,
}

/// Permission choices a request advertises beyond approve and decline. Each response that uses
/// one is rejected unless the request advertised it.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PermissionOptions {
    /// `allow_all_edits` (also offered by plan review): accept and switch the session's mode.
    pub allow_all_edits: bool,
    /// `allow_auto_mode`: accept and switch the session to auto mode.
    pub allow_auto_mode: bool,
    /// `permission_directories`: the exact directory scope offered for the session.
    pub permission_directories: Vec<String>,
    /// `remember_scope`.
    pub remember: Option<RememberScope>,
    /// `exit_plan_mode.plan`: the plan under review.
    pub plan: Option<String>,
    /// Codex command details.
    pub command: Option<CommandApproval>,
    /// `execpolicy_amendment`: the command policy the user may approve, exactly as offered.
    pub exec_policy_amendment: Option<Vec<String>>,
    /// Codex MCP tool-call persistence modes (`_meta.persist` with
    /// `_meta.codex_approval_kind == "mcp_tool_call"`).
    pub persist_modes: Vec<PersistMode>,
    /// Antigravity details.
    pub antigravity: Option<AntigravityPermission>,
    /// The files the gated edit would change (see [`FileChange`]); empty when the request is not
    /// an edit or does not say.
    pub file_changes: Vec<FileChange>,
}

impl PermissionOptions {
    fn from_params(phase: Option<&str>, preview: Option<&str>, extra: &Map<String, Value>) -> Self {
        let text = |key: &str| {
            extra
                .get(key)
                .and_then(Value::as_str)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        let plan = extra
            .get("exit_plan_mode")
            .and_then(|plan| plan.get("plan"))
            .and_then(Value::as_str)
            .filter(|plan| !plan.is_empty())
            .map(str::to_owned);
        let remember = extra.get("remember_scope").and_then(|scope| {
            let tool = scope.get("tool").and_then(Value::as_str)?;
            Some(RememberScope {
                tool: tool.to_owned(),
                host: scope.get("host").and_then(Value::as_str).map(str::to_owned),
            })
        });
        Self {
            allow_all_edits: extra.get("allow_all_edits") == Some(&Value::Bool(true))
                || plan.is_some(),
            allow_auto_mode: extra.get("allow_auto_mode") == Some(&Value::Bool(true)),
            permission_directories: nonempty_strings(extra.get("permission_directories"))
                .unwrap_or_default(),
            remember,
            plan,
            command: text("command").map(|command| CommandApproval {
                command,
                cwd: text("cwd"),
                reason: text("reason"),
            }),
            exec_policy_amendment: nonempty_strings(extra.get("execpolicy_amendment")),
            persist_modes: codex_persist_modes(extra.get("_meta")),
            antigravity: (phase == Some(AGY_PERMISSION_PHASE)).then(|| AntigravityPermission {
                action_description: text("action_description"),
                always_allow_pattern: text("always_allow_pattern"),
            }),
            file_changes: changes::file_changes(phase, preview, extra),
        }
    }

    /// Whether accepting with `_meta.persist = mode` was offered (Codex MCP modes, or
    /// Antigravity's always-allow pattern).
    #[must_use]
    pub fn offers_persist(&self, mode: PersistMode) -> bool {
        self.persist_modes.contains(&mode)
            || self
                .antigravity
                .as_ref()
                .is_some_and(|agy| agy.always_allow_pattern.is_some())
    }
}

/// A non-empty array of non-empty strings, else `None`.
fn nonempty_strings(value: Option<&Value>) -> Option<Vec<String>> {
    let values = value?.as_array().filter(|values| !values.is_empty())?;
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        })
        .collect()
}

fn codex_persist_modes(meta: Option<&Value>) -> Vec<PersistMode> {
    let Some(meta) = meta.and_then(Value::as_object) else {
        return Vec::new();
    };
    if meta.get("codex_approval_kind").and_then(Value::as_str) != Some("mcp_tool_call") {
        return Vec::new();
    }
    let mut modes: Vec<PersistMode> = match meta.get("persist") {
        Some(Value::Array(values)) => values.iter().filter_map(PersistMode::parse).collect(),
        Some(value) => PersistMode::parse(value).into_iter().collect(),
        None => Vec::new(),
    };
    modes.sort();
    modes.dedup();
    modes
}

/// One decision card.
#[derive(Debug, Clone, PartialEq)]
pub struct Decision {
    /// The elicitation id. Resolution requires this exact id.
    pub id: String,
    /// The session whose stream or snapshot carried the card.
    pub carrying_session_id: String,
    /// The session the answer is posted to: `params.target_session_id` for a card mirrored from
    /// a child session, else the carrying session.
    pub target_session_id: String,
    /// Card title.
    pub title: String,
    /// Card body: message, command, preview, plan, policy and command metadata.
    pub detail: String,
    /// The agent's or policy's message on its own, when it sent one.
    pub message: Option<String>,
    /// The gated tool call's input formatted for display (the web's `formatPreview`), when the
    /// card shows it: not for forms, plan reviews or Codex commands, which show their own fields.
    pub tool_input: Option<String>,
    /// What the card asks for.
    pub kind: DecisionKind,
    /// Permission choices beyond approve and decline.
    pub permissions: PermissionOptions,
    /// Policy phase as sent.
    pub phase: Option<String>,
    /// Policy name as sent.
    pub policy_name: Option<String>,
}

impl Decision {
    /// Builds the card for `request`, carried by `carrying_session_id`. Never fails: anything
    /// that cannot be rendered exactly becomes [`DecisionKind::Unsupported`].
    #[must_use]
    pub fn from_request(request: &ElicitationRequest, carrying_session_id: &str) -> Self {
        let params = &request.params;
        let preview = params.content_preview.as_deref().unwrap_or_default();
        let kind = request_kind(request);
        let permissions = PermissionOptions::from_params(
            params.phase.as_deref(),
            params.content_preview.as_deref(),
            &params.extra,
        );
        let message = params
            .message
            .as_deref()
            .map(str::trim)
            .filter(|message| !message.is_empty())
            .map(str::to_owned);
        let shows_own_fields = matches!(kind, DecisionKind::Form(_))
            || permissions.plan.is_some()
            || permissions.command.is_some();
        let tool_input = if shows_own_fields {
            None
        } else {
            changes::format_preview(preview)
        };
        let detail = detail_text(
            params.message.as_deref(),
            preview,
            matches!(kind, DecisionKind::Form(_)),
            &permissions,
        );
        let title = if permissions.plan.is_some() {
            "Review the plan"
        } else if matches!(kind, DecisionKind::Choice { .. } | DecisionKind::Form(_)) {
            "Response requested"
        } else {
            "Approval requested"
        };
        Self {
            id: request.elicitation_id.clone(),
            carrying_session_id: carrying_session_id.to_owned(),
            target_session_id: request.target_session(carrying_session_id).to_owned(),
            title: title.to_owned(),
            detail,
            message,
            tool_input,
            kind,
            permissions,
            phase: params.phase.clone(),
            policy_name: params.policy_name.clone(),
        }
    }

    /// Why the card cannot be answered natively, if it cannot.
    #[must_use]
    pub const fn unsupported_reason(&self) -> Option<&UnsupportedReason> {
        match &self.kind {
            DecisionKind::Unsupported { reason, .. } => Some(reason),
            _ => None,
        }
    }

    /// The safe confirmation page to offer as an explicit handoff, if any.
    #[must_use]
    pub fn external_url(&self) -> Option<&str> {
        match &self.kind {
            DecisionKind::Unsupported { external_url, .. } => external_url.as_deref(),
            _ => None,
        }
    }

    /// The typed form, if the card is one.
    #[must_use]
    pub const fn form(&self) -> Option<&DecisionForm> {
        match &self.kind {
            DecisionKind::Form(form) => Some(form),
            _ => None,
        }
    }

    /// Whether the card is a plan review.
    #[must_use]
    pub const fn is_plan_review(&self) -> bool {
        self.permissions.plan.is_some()
    }

    /// Whether a decline can carry feedback the agent receives
    /// ([`DecisionResponse::DeclineWithFeedback`]): plan reviews, and approvals from a native
    /// permission hook that forwards it.
    #[must_use]
    pub fn accepts_feedback(&self) -> bool {
        if self.kind != DecisionKind::Approval {
            return false;
        }
        self.is_plan_review()
            || (self.phase.as_deref() == Some(PRE_TOOL_USE_PHASE)
                && self
                    .policy_name
                    .as_deref()
                    .is_some_and(|policy| FEEDBACK_POLICIES.contains(&policy)))
    }

    /// The "don't ask again" label (host, else tool), if offered.
    #[must_use]
    pub fn remember_label(&self) -> Option<&str> {
        self.permissions.remember.as_ref().map(RememberScope::label)
    }

    /// Whether the card was mirrored from another (child) session.
    #[must_use]
    pub fn targets_other_session(&self) -> bool {
        self.target_session_id != self.carrying_session_id
    }
}

fn single_enum_choice(
    schema: &Map<String, Value>,
    properties: &Map<String, Value>,
) -> Option<DecisionKind> {
    let mut entries = properties.iter();
    let (key, property) = entries.next()?;
    if entries.next().is_some() {
        return None;
    }
    let property = property.as_object()?;
    if !property.keys().all(|key| key == "type" || key == "enum") {
        return None;
    }
    let options: Vec<String> = property
        .get("enum")?
        .as_array()?
        .iter()
        .map(|value| value.as_str().map(str::to_owned))
        .collect::<Option<_>>()?;
    if options.is_empty() || DecisionForm::from_schema(schema).is_err() {
        return None;
    }
    Some(DecisionKind::Choice {
        answer_key: key.clone(),
        options,
    })
}

fn schema_kind(schema: Option<&Value>) -> DecisionKind {
    let unsupported = |reason| DecisionKind::Unsupported {
        reason,
        external_url: None,
    };
    let schema = match schema {
        None | Some(Value::Null) => return DecisionKind::Approval,
        Some(Value::Object(schema)) => schema,
        Some(_) => return unsupported(UnsupportedReason::NonObjectSchema),
    };
    let empty = Map::new();
    let properties = schema
        .get("properties")
        .and_then(Value::as_object)
        .unwrap_or(&empty);
    if let Some(choice) = single_enum_choice(schema, properties) {
        return choice;
    }
    if !properties.is_empty() {
        return match DecisionForm::from_schema(schema) {
            Ok(form) => DecisionKind::Form(form),
            Err(error) => unsupported(UnsupportedReason::Schema(error)),
        };
    }
    // An empty or property-less object schema is a plain approval, unless it carries keywords a
    // binary answer would ignore.
    let only_plain_keys = schema.keys().all(|key| {
        matches!(
            key.as_str(),
            "type" | "properties" | "title" | "description" | "$schema" | "additionalProperties"
        )
    });
    let bad_type = schema
        .get("type")
        .is_some_and(|kind| kind.as_str() != Some("object"));
    let bad_properties = schema
        .get("properties")
        .is_some_and(|properties| !properties.is_object());
    if bad_type || bad_properties || !only_plain_keys {
        return unsupported(UnsupportedReason::Schema(FormError::NotAnObjectSchema));
    }
    DecisionKind::Approval
}

/// The `AskUserQuestion` payload: the structured extra, else a parsed `content_preview` call.
/// `None` when neither is present; an error when the preview names the call but is not JSON.
fn question_payload(request: &ElicitationRequest) -> Option<Result<Value, FormError>> {
    if let Some(question) = request
        .params
        .extra
        .get("ask_user_question")
        .filter(|question| !question.is_null())
    {
        return Some(Ok(question.clone()));
    }
    let preview = request.params.content_preview.as_deref()?;
    let arguments = preview.strip_prefix(ASK_USER_QUESTION_CALL)?;
    // A truncated or malformed preview that names the call fails closed rather than falling back
    // to a binary approval of a question.
    Some(
        arguments
            .strip_suffix(')')
            .ok_or_else(|| FormError::MalformedPreview {
                message: "the call is not closed".to_owned(),
            })
            .and_then(|json| {
                serde_json::from_str(json).map_err(|error| FormError::MalformedPreview {
                    message: error.to_string(),
                })
            }),
    )
}

fn is_safe_external_url(raw: &str) -> bool {
    Url::parse(raw).is_ok_and(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.host_str().is_some_and(|host| !host.is_empty())
            && url.username().is_empty()
            && url.password().is_none()
    })
}

fn request_kind(request: &ElicitationRequest) -> DecisionKind {
    let params = &request.params;
    // A structured question replaces whatever the schema said.
    let mut kind = question_payload(request).map_or_else(
        || schema_kind(params.requested_schema.as_ref()),
        |payload| match payload.and_then(|payload| DecisionForm::from_questions(&payload)) {
            Ok(form) => DecisionKind::Form(form),
            Err(error) => DecisionKind::Unsupported {
                reason: UnsupportedReason::Question(error),
                external_url: None,
            },
        },
    );
    let url = params.url.as_deref().filter(|url| !url.is_empty());
    if let Some(url) = url.filter(|url| !url.starts_with("/approve/")) {
        kind = if is_safe_external_url(url) {
            DecisionKind::Unsupported {
                reason: UnsupportedReason::ExternalConfirmation,
                external_url: Some(url.to_owned()),
            }
        } else {
            DecisionKind::Unsupported {
                reason: UnsupportedReason::UnsafeConfirmationUrl,
                external_url: None,
            }
        };
    }
    match &params.mode {
        ElicitationMode::Unknown { value } => DecisionKind::Unsupported {
            reason: UnsupportedReason::UnknownMode {
                mode: value.clone(),
            },
            external_url: None,
        },
        ElicitationMode::Url if url.is_none() => DecisionKind::Unsupported {
            reason: UnsupportedReason::MissingConfirmationUrl,
            external_url: None,
        },
        ElicitationMode::Form | ElicitationMode::Url => kind,
    }
}

fn detail_text(
    message: Option<&str>,
    preview: &str,
    is_form: bool,
    permissions: &PermissionOptions,
) -> String {
    let policy = permissions
        .exec_policy_amendment
        .as_ref()
        .map(|amendment| format!("Suggested command policy: {}", amendment.join(" ")));
    let command = permissions.command.as_ref();
    let parts = [
        message.map(str::to_owned),
        command.map(|command| command.command.clone()),
        (!is_form).then(|| preview.to_owned()),
        permissions.plan.clone(),
        policy,
        command
            .and_then(|command| command.cwd.as_ref())
            .map(|cwd| format!("Working directory: {cwd}")),
        command
            .and_then(|command| command.reason.as_ref())
            .map(|reason| format!("Reason: {reason}")),
        permissions
            .antigravity
            .as_ref()
            .and_then(|agy| agy.action_description.clone()),
    ];
    let detail: Vec<String> = parts
        .into_iter()
        .flatten()
        .filter(|part| !part.is_empty())
        .collect();
    if detail.is_empty() {
        "The server is waiting for your response.".to_owned()
    } else {
        detail.join("\n\n")
    }
}

#[cfg(test)]
mod changes_tests;
#[cfg(test)]
mod tests;
