//! Decision (elicitation) cards: elicitation schema to typed form to resolve body.
//!
//! - [`Decision::from_request`] turns a wire [`ElicitationRequest`] into a card: a binary
//!   approval (with any permission options the request advertises), a single-field choice, a
//!   typed [`DecisionForm`], a page to complete (URL mode), or an [`UnsupportedReason`]. Anything
//!   it cannot render exactly fails closed; it never becomes a binary approval.
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
pub mod permission_updates;
pub mod resolve;
mod text_format;

use omnigent_protocol::{ElicitationAction, ElicitationMode, ElicitationRequest};
use serde_json::{Map, Value, json};
use url::Url;

pub use changes::{FileChange, FileChangeKind};
pub use form::{
    AnswerError, DecisionForm, FieldKind, FormError, FormField, FormOption, FormProblem,
};
pub use ledger::{
    DecisionEntry, DecisionEventOutcome, DecisionState, MAX_RETIRED_IDS, RequestOutcome,
    ResolvedOutcome, SessionDecisions,
};
pub use permission_updates::{
    PermissionMode, PermissionRule, PermissionUpdate, RuleBehavior, UpdateChange, UpdateDestination,
};
pub use resolve::{
    DecisionError, DecisionResponse, ResolveAcknowledgement, ResolveError, ResolveRequest,
    ResolveRoute, resolve_response,
};
pub use text_format::TextFormat;

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
    /// URL mode: the user completes the request on a page, then answers Done (accept) or
    /// Decline. The page is a safe `http(s)` URL that is only ever opened explicitly.
    ExternalPage {
        /// The page.
        url: String,
    },
    /// Cannot be answered in the native app.
    Unsupported {
        /// Why.
        reason: UnsupportedReason,
        /// A safe `http(s)` confirmation page the user may open explicitly. Never opened
        /// automatically.
        external_url: Option<String>,
    },
}

/// Why a card cannot be answered natively. The display text is user-facing and names what the
/// app cannot do.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum UnsupportedReason {
    /// `requestedSchema` is not an object.
    #[error(
        "This form's schema is not a JSON object, so the app cannot show its fields. Continue in the web app."
    )]
    NonObjectSchema,
    /// The schema cannot become a native form.
    #[error("The app cannot show this form exactly: {0}. Continue in the web app.")]
    Schema(FormError),
    /// The `AskUserQuestion` payload cannot become a native form.
    #[error("The app cannot show this question exactly: {0}. Continue in the web app.")]
    Question(FormError),
    /// A page address that is not a credential-free `http(s)` URL.
    #[error(
        "This request's page address is not a plain http or https link, so the app will not open it. Continue in the web app."
    )]
    UnsafeConfirmationUrl,
    /// URL mode without a page address.
    #[error("This request asks you to open a page but did not say which. Continue in the web app.")]
    MissingConfirmationUrl,
    /// A `mode` this client does not know.
    #[error("This request uses the {mode:?} mode, which the app does not support yet.")]
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

/// Where a verdict a native terminal must confirm stands (`native_delivery.state`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum NativeDeliveryState {
    /// `ready`: waiting for a verdict.
    Ready,
    /// `sending`: a verdict is on its way to the terminal; the card waits for its receipt.
    Sending,
    /// `unconfirmed`: the terminal never confirmed the verdict; only that verdict may be resent.
    Unconfirmed,
}

/// `params.native_delivery`: a native terminal (Kiro) applies the verdict and confirms it, so the
/// card stays pending until it does. Every answer carries `_meta.native_delivery_attempt`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NativeDelivery {
    /// Where delivery stands.
    pub state: NativeDeliveryState,
    /// The attempt the answer must name.
    pub attempt: String,
    /// The verdict being delivered (sending or unconfirmed only).
    pub action: Option<ElicitationAction>,
}

impl NativeDelivery {
    /// Parses `native_delivery` as the web does: an unknown state, a blank attempt, or a sending
    /// or unconfirmed state without a known action is not a delivery.
    fn parse(value: Option<&Value>) -> Option<Self> {
        let object = value?.as_object()?;
        let attempt = object
            .get("attempt")
            .and_then(Value::as_str)
            .filter(|attempt| !attempt.is_empty())?;
        let state = match object.get("state").and_then(Value::as_str)? {
            "ready" => NativeDeliveryState::Ready,
            "sending" => NativeDeliveryState::Sending,
            "unconfirmed" => NativeDeliveryState::Unconfirmed,
            _ => return None,
        };
        let action = match object.get("action").and_then(Value::as_str) {
            Some("accept") => Some(ElicitationAction::Accept),
            Some("decline") => Some(ElicitationAction::Decline),
            Some("cancel") => Some(ElicitationAction::Cancel),
            _ => None,
        };
        if state != NativeDeliveryState::Ready && action.is_none() {
            return None;
        }
        Some(Self {
            state,
            attempt: attempt.to_owned(),
            action,
        })
    }
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
    /// `approval_request_fingerprint`: the digest of the displayed command request. A server
    /// that sends it derives the remembered policy itself and wants the digest echoed back;
    /// older servers omit it and take the policy in the answer.
    pub approval_request_fingerprint: Option<String>,
    /// Codex MCP tool-call persistence modes (`_meta.persist` with
    /// `_meta.codex_approval_kind == "mcp_tool_call"`).
    pub persist_modes: Vec<PersistMode>,
    /// Antigravity details.
    pub antigravity: Option<AntigravityPermission>,
    /// The files the gated edit would change (see [`FileChange`]); empty when the request is not
    /// an edit or does not say.
    pub file_changes: Vec<FileChange>,
    /// `permission_suggestions`: the updates Claude offers to apply with an approval, offered as
    /// one choice. Empty when none were sent, when any cannot be described, or when the choices
    /// above already cover every one.
    pub suggestions: Vec<PermissionUpdate>,
    /// `plan_modes`: the modes approving the plan may switch to (plan reviews only).
    pub plan_modes: Vec<PermissionMode>,
    /// A native terminal confirms the verdict (Kiro).
    pub native_delivery: Option<NativeDelivery>,
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
        let plan_modes = if plan.is_some() {
            permission_updates::plan_modes(extra.get("plan_modes"))
        } else {
            Vec::new()
        };
        let mut options = Self {
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
            approval_request_fingerprint: text("approval_request_fingerprint"),
            persist_modes: codex_persist_modes(extra.get("_meta")),
            antigravity: (phase == Some(AGY_PERMISSION_PHASE)).then(|| AntigravityPermission {
                action_description: text("action_description"),
                always_allow_pattern: text("always_allow_pattern"),
            }),
            file_changes: changes::file_changes(phase, preview, extra),
            suggestions: permission_updates::permission_updates(
                extra.get("permission_suggestions"),
            ),
            plan_modes,
            native_delivery: NativeDelivery::parse(extra.get("native_delivery")),
        };
        if options
            .suggestions
            .iter()
            .all(|update| options.covers(update))
        {
            options.suggestions.clear();
        }
        options
    }

    /// Whether another choice on the card applies `update` already: "accept all edits" for the
    /// session, or the offered session directories.
    fn covers(&self, update: &PermissionUpdate) -> bool {
        if update.destination != UpdateDestination::Session {
            return false;
        }
        match &update.change {
            UpdateChange::SetMode {
                mode: PermissionMode::AcceptEdits,
            } => self.allow_all_edits && self.plan.is_none(),
            UpdateChange::AddDirectories { directories } => directories
                .iter()
                .all(|directory| self.permission_directories.contains(directory)),
            _ => false,
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
    /// The agent keeps working while the card waits (`is_blocking: false`, as Codex's
    /// non-blocking questions are), so the card does not mean the agent is waiting for you.
    pub agent_keeps_working: bool,
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
        // Forms and pages show their own fields; the preview is the raw request.
        let hides_preview = matches!(
            kind,
            DecisionKind::Form(_) | DecisionKind::ExternalPage { .. }
        );
        let shows_own_fields =
            hides_preview || permissions.plan.is_some() || permissions.command.is_some();
        let tool_input = if shows_own_fields {
            None
        } else {
            changes::format_preview(preview)
        };
        let detail = detail_text(
            params.message.as_deref(),
            preview,
            hides_preview,
            &permissions,
        );
        let delivery = permissions
            .native_delivery
            .as_ref()
            .map(|delivery| delivery.state);
        let title = if permissions.plan.is_some() {
            "Review the plan"
        } else if delivery == Some(NativeDeliveryState::Sending) {
            "Waiting for the agent to confirm"
        } else if delivery == Some(NativeDeliveryState::Unconfirmed) {
            "Approval delivery unconfirmed"
        } else if matches!(kind, DecisionKind::ExternalPage { .. }) {
            "Action required"
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
            agent_keeps_working: params.extra.get("is_blocking") == Some(&Value::Bool(false)),
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

    /// The safe page to offer as an explicit handoff, if any.
    #[must_use]
    pub fn external_url(&self) -> Option<&str> {
        match &self.kind {
            DecisionKind::ExternalPage { url } => Some(url),
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

    /// Whether the native terminal never confirmed the verdict sent for this card, so it may be
    /// sent again (see [`NativeDelivery`]).
    #[must_use]
    pub fn awaits_redelivery(&self) -> bool {
        self.permissions
            .native_delivery
            .as_ref()
            .is_some_and(|delivery| delivery.state == NativeDeliveryState::Unconfirmed)
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
    // binary answer would ignore. An empty `required` list asks for nothing.
    let only_plain_keys = schema.iter().all(|(key, value)| match key.as_str() {
        "type" | "properties" | "title" | "description" | "$schema" | "additionalProperties" => {
            true
        }
        "required" => value.as_array().is_some_and(Vec::is_empty),
        _ => false,
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

/// The `AskUserQuestion` payload: the structured extra when it lists questions, else the
/// questions a `content_preview` call spells out whole. `None` when there are none: the request
/// is then the tool's approval, as on the web.
fn question_payload(request: &ElicitationRequest) -> Option<Value> {
    let structured = request.params.extra.get("ask_user_question");
    if let Some(payload) = structured.filter(|payload| {
        payload
            .get("questions")
            .and_then(Value::as_array)
            .is_some_and(|questions| !questions.is_empty())
    }) {
        return Some(payload.clone());
    }
    preview_questions(request.params.content_preview.as_deref()?)
}

/// The questions an `AskUserQuestion(...)` preview spells out, read as the web reads them: a
/// question without text or options, and an option without a label, are left out. `None` for a
/// cut or malformed preview, or one with no question left.
fn preview_questions(preview: &str) -> Option<Value> {
    let arguments = preview
        .strip_prefix(ASK_USER_QUESTION_CALL)?
        .strip_suffix(')')?;
    let payload: Value = serde_json::from_str(arguments).ok()?;
    let text = |value: &Value, key: &str| {
        value
            .get(key)
            .and_then(Value::as_str)
            .filter(|text| !text.is_empty())
            .map(str::to_owned)
    };
    let questions: Vec<Value> = payload
        .get("questions")?
        .as_array()?
        .iter()
        .filter_map(|question| {
            let options: Vec<Value> = question
                .get("options")?
                .as_array()?
                .iter()
                .filter_map(|option| {
                    let mut kept = Map::new();
                    kept.insert("label".to_owned(), Value::String(text(option, "label")?));
                    for key in ["description", "preview"] {
                        if let Some(value) = text(option, key) {
                            kept.insert(key.to_owned(), Value::String(value));
                        }
                    }
                    Some(Value::Object(kept))
                })
                .collect();
            if options.is_empty() {
                return None;
            }
            let mut kept = Map::new();
            kept.insert(
                "question".to_owned(),
                Value::String(text(question, "question")?),
            );
            kept.insert("options".to_owned(), Value::Array(options));
            for key in ["header", "id"] {
                if let Some(value) = text(question, key) {
                    kept.insert(key.to_owned(), Value::String(value));
                }
            }
            for flag in ["multiSelect", "isSecret"] {
                if question.get(flag) == Some(&Value::Bool(true)) {
                    kept.insert(flag.to_owned(), Value::Bool(true));
                }
            }
            Some(Value::Object(kept))
        })
        .collect();
    (!questions.is_empty()).then(|| json!({ "questions": questions }))
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
        |payload| match DecisionForm::from_questions(&payload) {
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
            DecisionKind::ExternalPage {
                url: url.to_owned(),
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
    hides_preview: bool,
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
        (!hides_preview).then(|| preview.to_owned()),
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
mod claude_tests;
#[cfg(test)]
mod codex_tests;
#[cfg(test)]
mod harness_tests;
#[cfg(test)]
mod omni_tests;
#[cfg(test)]
mod tests;
