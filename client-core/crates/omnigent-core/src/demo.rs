//! The offline sample workspace, served as a server: an [`HttpTransport`] that answers the
//! session REST routes from in-memory state, for previews, snapshots and the offline demo.
//!
//! Port of `NativeLab`'s `DemoSessionClient`, `DemoFixtures` and `DemoConfiguration`, moved one
//! layer down: instead of a second client, the demo is a fake server, so the real
//! [`crate::ClientCore`] (every guard, ledger and decoder) runs unchanged on top of it. Connect
//! with [`demo_endpoint`] and no bearer.
//!
//! The sample sessions come from `fixtures/sessions/DemoFixtures--*.json`. State is a
//! [`Workspace`], so it saves and restores through [`crate::workspace_store`]; a restored
//! workspace is recovered first, and sessions saved before configuration existed are upgraded to
//! [`demo_configuration`].
//!
//! The demo never reads a clock or sleeps: [`DemoTransport::set_now`] sets the time stamped on
//! activity, and [`DemoTransport::advance_replies`] streams the next word of every running
//! sample reply (the host calls it on a timer). Ids come from a counter that restarts above every
//! id in the loaded state, so a relaunch never reuses one.
//!
//! The server rules the demo enforces (the client enforces its own on top): read-only sessions
//! (permission below edit) reject writes with 403 and archive needs owner; a message to an
//! archived session, a session with a pending decision, or a session already replying is a 409;
//! `PATCH` rejects unknown fields with 422, as the real server does.

use std::collections::{BTreeMap, BTreeSet};
use std::future::{Future, ready};
use std::sync::{Mutex, PoisonError};

use omnigent_protocol::sessions::{SessionSnapshot, SessionStatus};
use omnigent_protocol::{
    ContentPart, ConversationItem, Field, FromWire, ItemData, ItemStatus, TextPartKind,
};
use serde_json::{Map, Value, json};
use url::Url;

use crate::auth::endpoint::ServerEndpoint;
use crate::auth::errors::HostedAuthError;
use crate::config::approval::{APPROVAL_MODE_LABEL, PERMISSION_MODE_LABEL};
use crate::config::session::{
    ConfigurationCatalog, ConfigurationHost, HarnessChoice, ModelChoice, ReasoningChoice,
    SessionConfiguration,
};
use crate::creation::HarnessReadiness;
use crate::http::{HttpHeader, HttpRequest, HttpResponse, HttpTransport, TransportError};
use crate::workspace_store::{Workspace, WorkspaceError, WorkspaceSession, append_text};

/// The demo's API root. The transport answers it without any network access.
pub const DEMO_SERVER_URL: &str = "http://127.0.0.1:6767";
/// The demo host's id.
pub const DEMO_HOST_ID: &str = "demo-host";
/// The sample reply the demo streams for a message.
pub const DEMO_REPLY_TEXT: &str = "Got it. This is a sample reply from the offline demo. Your message stayed in this conversation. You can try another message or create a new session.";
/// The reply to a message that asks for detail: long and slow enough to queue follow-ups, with
/// files, while it streams.
pub const DEMO_DETAILED_REPLY_TEXT: &str = "Here is the detailed version. The offline demo streams this answer one word at a time so there \
is time to try what a running turn allows: type a follow-up and queue it for after this turn, \
attach a file or an image to it, steer the agent with Send now, or stop the reply. Queued \
messages wait in the strip above the composer, keep their files and paths, and send in order as \
soon as the turn ends. You can edit a queued message before it goes, move it back into the \
composer, or remove it, and the queue keeps the rest in the order you added them. The open \
questions in the sample sessions fall into three groups. The first is the approval flow: \
whether a reviewer must approve every change or only those that touch shared settings, and who \
can approve when the usual reviewer is away. The second is the rollout: whether the new layout \
ships to everyone at once or to a small group first, and what the team watches before widening \
it. The third is the cleanup: which old screens can go once the new ones are in place, and how \
long the old links keep working for people who saved them. Each question has a draft answer in \
the design notes, but none is settled yet, so the next step is to pick an owner for each one \
and agree on a date to decide. Until then the work can continue on the parts that do not depend \
on the answers, such as the layout of the review screen and the wording of the notices people \
see when something changes. For the approval flow, the draft suggests that changes to shared \
settings always need a second reviewer, while changes that stay inside one project need only \
the owner. When the usual reviewer is away, anyone listed as a backup for that project can \
approve, and the session notes who did. The open part is whether a backup can approve their own \
change, which the draft leaves to each team for now. For the rollout, the draft starts with the \
people who asked for the new layout, then widens to each team in turn over two weeks. The team \
watches how often people switch back to the old layout, how long reviews take, and how many \
questions come in about where things moved. If any of those get worse, the rollout pauses until \
the cause is understood and fixed. For the cleanup, the draft keeps the old screens for one \
release after everyone has moved, then removes them. Saved links to old screens open the \
matching new screen, with a short notice that explains the move, for at least six months. The \
open part is what to do with reports that only exist on the old screens, which may need to be \
rebuilt or retired. If you want, I can turn these into a short checklist with an owner and a \
date for each item, or draft the message that asks each owner to confirm. Either way, the \
decisions are small enough to make in one meeting if the owners read the notes beforehand. \
Nothing here reaches a real agent or host, and every session stays on this device until you \
connect to a server.";
/// Ticks per word of [`DEMO_DETAILED_REPLY_TEXT`].
const DETAILED_REPLY_TICKS_PER_WORD: usize = 3;
/// The text appended to a reply the user stopped.
pub const REPLY_STOPPED: &str = "Reply stopped.";
/// The title of a session created without one.
pub const DEFAULT_TITLE: &str = "New conversation";
/// Seconds between the Swift reference date (2001-01-01) and the Unix epoch.
const SWIFT_REFERENCE_OFFSET: f64 = 978_307_200.0;
/// The `PATCH /v1/sessions/{id}` fields the demo supports; anything else is a 422.
const PATCH_FIELDS: [&str; 7] = [
    "title",
    "labels",
    "archived",
    "model_override",
    "reasoning_effort",
    "permission_mode",
    "approval_mode",
];
/// The demo's time until the host sets one: the fixtures' reference instant.
pub const DEFAULT_NOW: i64 = 1_700_000_000;

const FIXTURES: [&str; 3] = [
    include_str!("../../../fixtures/sessions/DemoFixtures--demo-design.json"),
    include_str!("../../../fixtures/sessions/DemoFixtures--demo-question.json"),
    include_str!("../../../fixtures/sessions/DemoFixtures--demo-notes.json"),
];

/// The endpoint to connect a [`crate::ClientCore`] over a [`DemoTransport`] with.
///
/// # Errors
///
/// Never in practice; [`ServerEndpoint::new`]'s error type.
pub fn demo_endpoint() -> Result<ServerEndpoint, HostedAuthError> {
    ServerEndpoint::new(DEMO_SERVER_URL)
}

fn demo_models() -> Vec<ModelChoice> {
    let effort = |value: &str| ReasoningChoice {
        reasoning_effort: value.to_owned(),
        description: None,
    };
    vec![
        ModelChoice {
            id: "sample-balanced".into(),
            display_name: Some("Sample Balanced".into()),
            description: Some("Offline preview only".into()),
            is_default: Some(true),
            supported_reasoning_efforts: Some(vec![effort("low"), effort("high")]),
            ..ModelChoice::default()
        },
        ModelChoice {
            id: "sample-fast".into(),
            display_name: Some("Sample Fast".into()),
            description: Some("Offline preview only".into()),
            supported_reasoning_efforts: Some(vec![effort("low")]),
            ..ModelChoice::default()
        },
    ]
}

/// The configuration every demo session reports.
#[must_use]
pub fn demo_configuration() -> SessionConfiguration {
    SessionConfiguration {
        agent_id: Some("demo-codex".into()),
        harness: Some("codex-native".into()),
        wrapper: Some("codex-native-ui".into()),
        model_override: Some("sample-balanced".into()),
        model_reported: Some(true),
        effort_reported: Some(true),
        host_id: Some(DEMO_HOST_ID.into()),
        host_online: Some(true),
        runner_online: Some(true),
        models: demo_models(),
        ..SessionConfiguration::default()
    }
}

/// The harness-switch catalog of the demo host.
#[must_use]
pub fn demo_catalog() -> ConfigurationCatalog {
    ConfigurationCatalog {
        agents: demo_agents(),
        host: Some(ConfigurationHost {
            host_id: DEMO_HOST_ID.into(),
            name: "Offline demo host".into(),
            status: "online".into(),
            configured_harnesses: Some(BTreeMap::from([
                ("codex-native".to_owned(), HarnessReadiness::Ready),
                ("claude-native".to_owned(), HarnessReadiness::Ready),
            ])),
        }),
        ..ConfigurationCatalog::default()
    }
}

fn demo_agents() -> Vec<HarnessChoice> {
    vec![
        HarnessChoice {
            id: "demo-codex".into(),
            name: "Sample Codex".into(),
            harness: Some("codex-native".into()),
            builtin: Some(true),
        },
        HarnessChoice {
            id: "demo-claude".into(),
            name: "Sample Claude".into(),
            harness: Some("claude-native".into()),
            builtin: Some(true),
        },
    ]
}

fn wrapper_for(harness: &str) -> &'static str {
    if harness == "codex-native" {
        "codex-native-ui"
    } else {
        "claude-code-native-ui"
    }
}

/// Writes the demo configuration's fields onto a snapshot object.
fn configure_snapshot(object: &mut Map<String, Value>) {
    let configuration = demo_configuration();
    object.insert("agent_id".into(), json!(configuration.agent_id));
    object.insert("harness".into(), json!(configuration.harness));
    object.insert("model_override".into(), json!(configuration.model_override));
    object.insert("reasoning_effort".into(), Value::Null);
    object.insert("host_id".into(), json!(configuration.host_id));
    object.insert("host_online".into(), json!(true));
    object.insert("runner_online".into(), json!(true));
    object.insert(
        "model_options".into(),
        Value::Array(
            configuration
                .models
                .iter()
                .map(ModelChoice::to_value)
                .collect(),
        ),
    );
    let labels = object
        .entry("labels")
        .or_insert_with(|| Value::Object(Map::new()));
    if let Value::Object(labels) = labels {
        labels.insert("omnigent.wrapper".into(), json!(configuration.wrapper));
    }
}

fn fixture_error(message: impl Into<String>) -> WorkspaceError {
    WorkspaceError::Corrupt {
        message: message.into(),
    }
}

/// Converts one `DemoFixtures--*.json` (a Swift `ConversationSnapshot`) into a demo session
/// with no configuration yet; loading upgrades it.
fn fixture_session(text: &str) -> Result<WorkspaceSession, WorkspaceError> {
    let fixture: Value =
        serde_json::from_str(text).map_err(|error| fixture_error(error.to_string()))?;
    let session = fixture
        .get("session")
        .and_then(Value::as_object)
        .ok_or_else(|| fixture_error("fixture has no session"))?;
    let string = |key: &str| session.get(key).and_then(Value::as_str).unwrap_or_default();
    let flag = |key: &str| session.get(key).and_then(Value::as_bool).unwrap_or(false);
    let reference = session
        .get("updatedAt")
        .and_then(Value::as_f64)
        .ok_or_else(|| fixture_error("fixture has no updatedAt"))?;
    let updated_at = unix_seconds(reference + SWIFT_REFERENCE_OFFSET);
    let id = string("id");
    let mut labels = Map::new();
    if flag("isPinned") {
        labels.insert("omnigent.pinned".into(), json!(updated_at.to_string()));
    }
    let items: Vec<Value> = fixture
        .get("messages")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|message| {
            let role = message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("user");
            let kind = if role == "user" {
                "input_text"
            } else {
                "output_text"
            };
            let streaming = message.get("isStreaming").and_then(Value::as_bool) == Some(true);
            json!({
                "id": message.get("id"),
                "type": "message",
                "role": role,
                "status": if streaming { "in_progress" } else { "completed" },
                "content": [{"type": kind, "text": message.get("text")}],
            })
        })
        .collect();
    let pending: Vec<Value> = fixture
        .get("decisions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter(|decision| decision.get("response").is_none_or(Value::is_null))
        .map(fixture_decision)
        .collect();
    let snapshot = json!({
        "id": id,
        "status": if string("status") == "running" { "running" } else { "idle" },
        "created_at": updated_at,
        "updated_at": updated_at,
        "title": string("title"),
        "workspace": string("workspace"),
        "agent_name": string("agentName"),
        "labels": labels,
        "archived": flag("isArchived"),
        "permission_level": if flag("isReadOnly") { 1 } else { 4 },
        "items": items,
        "pending_elicitations": pending,
    });
    let revision = fixture
        .get("revision")
        .and_then(Value::as_u64)
        .ok_or_else(|| fixture_error("fixture has no revision"))?;
    Ok(WorkspaceSession {
        revision,
        snapshot: SessionSnapshot::from_value(snapshot)
            .map_err(|error| fixture_error(error.to_string()))?,
    })
}

/// A fixture decision as the elicitation the server would have sent: a binary approval, or a
/// single-choice question over its options.
fn fixture_decision(decision: &Value) -> Value {
    let text = |key: &str| {
        decision
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
    };
    let options: Vec<&str> = decision
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let schema = if options.is_empty() {
        json!({})
    } else {
        json!({
            "type": "object",
            "properties": {"choice": {"type": "string", "enum": options}},
            "required": ["choice"],
        })
    };
    let mut params = json!({
        "mode": "form",
        "message": format!("{}\n\n{}", text("title"), text("detail")),
        "requestedSchema": schema,
    });
    // A sample patch is gated like an SDK harness's `apply_patch` call.
    if let (Some(changes), Value::Object(params)) = (decision.get("changes"), &mut params) {
        params.insert(
            "content_preview".into(),
            json!(format!("apply_patch({})", json!({"changes": changes}))),
        );
        params.insert("phase".into(), json!("tool_call"));
    }
    json!({
        "elicitation_id": text("id"),
        "method": "elicitation/create",
        "params": params,
    })
}

#[allow(
    clippy::cast_possible_truncation,
    clippy::as_conversions,
    reason = "fixture timestamps are whole seconds well inside i64"
)]
const fn unix_seconds(value: f64) -> i64 {
    value as i64
}

/// The sample workspace from the fixtures, before recovery and upgrade.
///
/// # Errors
///
/// [`WorkspaceError::Corrupt`] when a fixture does not convert.
pub fn sample_workspace() -> Result<Workspace, WorkspaceError> {
    let sessions = FIXTURES
        .iter()
        .map(|text| fixture_session(text))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Workspace::new(sessions, BTreeMap::new()))
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ActiveReply {
    item_id: String,
    words_sent: usize,
    text: &'static str,
    /// Ticks between words, and the ticks since the last one.
    ticks_per_word: usize,
    idle_ticks: usize,
}

#[derive(Debug)]
struct DemoState {
    sessions: Vec<WorkspaceSession>,
    replies: BTreeMap<String, ActiveReply>,
    next_id: u64,
    now: i64,
    /// The viewer's read state per session (`last_seen`, `unread`), in memory like the server's.
    reads: BTreeMap<String, (i64, bool)>,
}

/// Why a demo route failed: an HTTP status and a `detail`.
struct Reject(u16, &'static str);

type Routed = Result<(u16, Value), Reject>;

/// The demo server.
#[derive(Debug)]
pub struct DemoTransport {
    state: Mutex<DemoState>,
}

impl DemoTransport {
    /// The demo serving `workspace`, recovered and upgraded.
    #[must_use]
    pub fn new(workspace: Workspace) -> Self {
        let mut recovered = workspace.recovering_interrupted_replies();
        for session in &mut recovered.sessions {
            if session.snapshot.harness.is_absent() {
                upgrade(session);
            }
        }
        let next_id = next_sequence(&recovered.sessions);
        Self {
            state: Mutex::new(DemoState {
                sessions: recovered.sessions,
                replies: BTreeMap::new(),
                next_id,
                now: DEFAULT_NOW,
                reads: BTreeMap::new(),
            }),
        }
    }

    /// The demo serving the sample workspace.
    ///
    /// # Errors
    ///
    /// As [`sample_workspace`].
    pub fn sample() -> Result<Self, WorkspaceError> {
        Ok(Self::new(sample_workspace()?))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, DemoState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Sets the time stamped on activity, in Unix seconds.
    pub fn set_now(&self, unix_seconds: i64) {
        self.lock().now = unix_seconds;
    }

    /// The current state, with `drafts`, for saving.
    #[must_use]
    pub fn workspace(&self, drafts: BTreeMap<String, String>) -> Workspace {
        Workspace::new(self.lock().sessions.clone(), drafts)
    }

    /// `session_id`'s revision; it increases with every change to the session.
    #[must_use]
    pub fn revision(&self, session_id: &str) -> Option<u64> {
        self.lock()
            .sessions
            .iter()
            .find(|session| session.snapshot.id == session_id)
            .map(|session| session.revision)
    }

    /// `session_id`'s saved state.
    #[must_use]
    pub fn session(&self, session_id: &str) -> Option<WorkspaceSession> {
        self.lock()
            .sessions
            .iter()
            .find(|session| session.snapshot.id == session_id)
            .cloned()
    }

    /// Whether any sample reply is streaming.
    #[must_use]
    pub fn is_replying(&self) -> bool {
        !self.lock().replies.is_empty()
    }

    /// Streams the next word of every running reply, finishing those with none left. Returns the
    /// sessions that changed.
    #[allow(
        clippy::significant_drop_tightening,
        reason = "the whole step is applied under one guard"
    )]
    pub fn advance_replies(&self) -> Vec<String> {
        let mut guard = self.lock();
        let DemoState {
            sessions,
            replies,
            now,
            ..
        } = &mut *guard;
        let mut changed = Vec::new();
        replies.retain(|session_id, reply| {
            let Some(session) = sessions
                .iter_mut()
                .find(|session| &session.snapshot.id == session_id)
            else {
                return false;
            };
            let Some(item) = session
                .snapshot
                .items
                .iter_mut()
                .find(|item| item.id == reply.item_id)
            else {
                return false;
            };
            reply.idle_ticks = reply.idle_ticks.saturating_add(1);
            if reply.idle_ticks < reply.ticks_per_word {
                return true;
            }
            reply.idle_ticks = 0;
            let streaming = if let Some(word) = reply.text.split(' ').nth(reply.words_sent) {
                append_word(item, word);
                reply.words_sent = reply.words_sent.saturating_add(1);
                true
            } else {
                item.status = Some(ItemStatus::Completed);
                session.snapshot.status = SessionStatus::Idle;
                false
            };
            session.revision = session.revision.saturating_add(1);
            session.snapshot.updated_at = Field::Present(*now);
            changed.push(session_id.clone());
            streaming
        });
        changed
    }

    fn handle(&self, request: &HttpRequest) -> HttpResponse {
        let routed = self.route(request);
        let (status, body) = match routed {
            Ok(response) => response,
            Err(Reject(status, detail)) => (status, json!({"detail": detail})),
        };
        HttpResponse {
            status,
            headers: vec![HttpHeader::new("Content-Type", "application/json")],
            body: serde_json::to_vec(&body).unwrap_or_default(),
        }
    }

    fn route(&self, request: &HttpRequest) -> Routed {
        let url = Url::parse(&request.url).map_err(|_| Reject(400, "Invalid URL"))?;
        let query: BTreeMap<String, String> = url.query_pairs().into_owned().collect();
        let segments: Vec<&str> = url
            .path_segments()
            .map(Iterator::collect)
            .unwrap_or_default();
        let body = || -> Result<Value, Reject> {
            request
                .body
                .as_deref()
                .map_or(Ok(Value::Null), serde_json::from_slice)
                .map_err(|_| Reject(400, "Invalid JSON body"))
        };
        let mut state = self.lock();
        match (request.method.as_str(), segments.as_slice()) {
            ("GET", ["v1", "info"]) => Ok((
                200,
                json!({"single_user": true, "accounts_enabled": false, "server_version": "demo"}),
            )),
            ("GET", ["v1", "me"]) => Ok((200, json!({"user_id": "local", "is_admin": true}))),
            ("GET", ["v1", "sessions"]) => Ok(state.list(&query)),
            ("POST", ["v1", "sessions"]) => state.create(&body()?),
            ("GET", ["v1", "sessions", id]) => state.snapshot(id),
            ("PATCH", ["v1", "sessions", id]) => state.patch(id, &body()?),
            ("DELETE", ["v1", "sessions", id]) => state.delete(id),
            ("GET", ["v1", "sessions", id, "items"]) => state.items(id, &query),
            // The sample agents declare no terminals.
            ("GET", ["v1", "sessions", id, "agent"]) => state
                .find(id)
                .map(|session| (200, json!({"id": session.snapshot.agent_id.value(), "object": "agent", "terminals": []}))),
            ("POST", ["v1", "sessions", id, "events"]) => state.event(id, &body()?),
            ("POST", ["v1", "sessions", id, "switch-agent"]) => state.switch_agent(id, &body()?),
            ("PUT", ["v1", "sessions", id, "read-state"]) => state.read_state(id, &body()?),
            // Files are accepted but not kept: the sample transcript shows only their names.
            ("POST", ["v1", "sessions", id, "resources", "files"]) => {
                state.find(id)?;
                let file_id = format!("demo-file-{}", state.allocate());
                Ok((201, json!({"id": file_id, "session_id": id})))
            }
            ("POST", ["v1", "sessions", id, "elicitations", decision, "resolve"]) => {
                state.resolve(id, decision, &body()?)
            }
            (
                "GET",
                [
                    "v1",
                    "sessions",
                    id,
                    "resources",
                    "environments",
                    _,
                    "changes",
                ],
            ) => state.find(id).map(|_| (200, json!({"entries": []}))),
            ("GET", ["v1", "hosts"]) => Ok((200, hosts())),
            ("GET", ["v1", "agents"]) => Ok((200, agents())),
            ("GET", ["v1", "hosts", DEMO_HOST_ID, "filesystem"]) => Ok((
                200,
                json!({"data": [
                    {"name": "demo", "path": "/demo", "type": "directory"},
                    {"name": "notes.txt", "path": "/demo-notes.txt", "type": "file"},
                ], "has_more": false}),
            )),
            ("GET", ["v1", "hosts", DEMO_HOST_ID, "harnesses", _, "model-options"]) => Ok((
                200,
                json!({"models": demo_models().iter().map(ModelChoice::to_value).collect::<Vec<_>>()}),
            )),
            _ => Err(Reject(404, "Not Found")),
        }
    }
}

impl HttpTransport for DemoTransport {
    fn send(
        &self,
        request: HttpRequest,
    ) -> impl Future<Output = Result<HttpResponse, TransportError>> {
        ready(Ok(self.handle(&request)))
    }
}

fn hosts() -> Value {
    json!({"hosts": [{
        "host_id": DEMO_HOST_ID,
        "name": "Offline demo host",
        "status": "online",
        "configured_harnesses": {"codex-native": true, "claude-native": true},
    }]})
}

fn agents() -> Value {
    let data: Vec<Value> = demo_agents()
        .iter()
        .map(|agent| json!({"id": agent.id, "name": agent.name, "harness": agent.harness, "builtin": true}))
        .collect();
    json!({"data": data, "has_more": false})
}

/// Gives a session saved before configuration existed the demo configuration.
fn upgrade(session: &mut WorkspaceSession) {
    let Ok(Value::Object(mut object)) = serde_json::to_value(&session.snapshot) else {
        return;
    };
    configure_snapshot(&mut object);
    if let Ok(snapshot) = SessionSnapshot::from_value(Value::Object(object)) {
        session.snapshot = snapshot;
        session.revision = session.revision.saturating_add(1);
    }
}

/// One past the largest numeric id suffix in `sessions`, so new ids never collide.
fn next_sequence(sessions: &[WorkspaceSession]) -> u64 {
    let suffix = |id: &str| {
        id.rsplit_once('-')
            .and_then(|(_, number)| number.parse::<u64>().ok())
    };
    sessions
        .iter()
        .flat_map(|session| {
            std::iter::once(suffix(&session.snapshot.id))
                .chain(session.snapshot.items.iter().map(|item| suffix(&item.id)))
        })
        .flatten()
        .max()
        .map_or(1, |max| max.saturating_add(1))
}

fn append_word(item: &mut ConversationItem, word: &str) {
    let ItemData::Message(message) = &mut item.data else {
        return;
    };
    let current = message.visible_text();
    let text = if current.is_empty() {
        word.to_owned()
    } else {
        format!("{current} {word}")
    };
    message.content = vec![ContentPart::Text {
        kind: TextPartKind::OutputText,
        text,
    }];
}

fn snapshot_json(session: &WorkspaceSession, include_items: bool) -> Value {
    let mut value = serde_json::to_value(&session.snapshot).unwrap_or(Value::Null);
    if !include_items && let Value::Object(object) = &mut value {
        object.insert("items".into(), Value::Array(Vec::new()));
    }
    value
}

fn permission(session: &WorkspaceSession) -> i64 {
    session
        .snapshot
        .permission_level
        .value()
        .copied()
        .unwrap_or(0)
}

/// `"default"`, `"off"` and `"reset"` clear an override, as the server's aliases do.
fn clearable(value: &Value) -> Result<Value, Reject> {
    match value {
        Value::Null => Ok(Value::Null),
        Value::String(text) if matches!(text.as_str(), "default" | "off" | "reset") => {
            Ok(Value::Null)
        }
        Value::String(_) => Ok(value.clone()),
        _ => Err(Reject(422, "Expected a string")),
    }
}

impl DemoState {
    fn find(&self, id: &str) -> Result<&WorkspaceSession, Reject> {
        self.sessions
            .iter()
            .find(|session| session.snapshot.id == id)
            .ok_or(Reject(404, "Session not found"))
    }

    fn find_mut(&mut self, id: &str) -> Result<&mut WorkspaceSession, Reject> {
        self.sessions
            .iter_mut()
            .find(|session| session.snapshot.id == id)
            .ok_or(Reject(404, "Session not found"))
    }

    const fn allocate(&mut self) -> u64 {
        let id = self.next_id;
        self.next_id = self.next_id.saturating_add(1);
        id
    }

    fn list(&self, query: &BTreeMap<String, String>) -> (u16, Value) {
        let include_archived = query.get("include_archived").map(String::as_str) == Some("true");
        let limit = query
            .get("limit")
            .and_then(|limit| limit.parse::<usize>().ok())
            .unwrap_or(20);
        let rows: Vec<&WorkspaceSession> = self
            .sessions
            .iter()
            .filter(|session| include_archived || session.snapshot.archived.value() != Some(&true))
            .collect();
        let start = query.get("after").map_or(0, |after| {
            rows.iter()
                .position(|session| &session.snapshot.id == after)
                .map_or(rows.len(), |index| index.saturating_add(1))
        });
        let page: Vec<Value> = rows
            .iter()
            .skip(start)
            .take(limit)
            .map(|session| {
                let mut row = snapshot_json(session, false);
                if let Value::Object(object) = &mut row {
                    object.remove("items");
                    object.remove("pending_elicitations");
                    object.insert(
                        "pending_elicitations_count".into(),
                        json!(session.snapshot.pending_elicitations.len()),
                    );
                    let read = self.reads.get(&session.snapshot.id);
                    object.insert(
                        "viewer_last_seen".into(),
                        json!(read.map(|(last_seen, _)| last_seen)),
                    );
                    object.insert(
                        "viewer_unread".into(),
                        json!(read.is_some_and(|(_, unread)| *unread)),
                    );
                }
                row
            })
            .collect();
        let has_more = start.saturating_add(page.len()) < rows.len();
        let id_at = |row: Option<&Value>| row.and_then(|row| row.get("id")).cloned();
        (
            200,
            json!({
                "object": "list",
                "first_id": id_at(page.first()),
                "last_id": id_at(page.last()),
                "has_more": has_more,
                "data": page,
            }),
        )
    }

    /// `PUT /v1/sessions/{id}/read-state`: stores `{last_seen, unread}` verbatim, as the server
    /// does.
    fn read_state(&mut self, id: &str, body: &Value) -> Routed {
        self.find(id)?;
        let last_seen = body
            .get("last_seen")
            .and_then(Value::as_i64)
            .ok_or(Reject(422, "last_seen must be an integer"))?;
        let unread = body
            .get("unread")
            .and_then(Value::as_bool)
            .ok_or(Reject(422, "unread must be a boolean"))?;
        self.reads.insert(id.to_owned(), (last_seen, unread));
        Ok((204, Value::Null))
    }

    fn snapshot(&self, id: &str) -> Routed {
        Ok((200, snapshot_json(self.find(id)?, false)))
    }

    fn items(&self, id: &str, query: &BTreeMap<String, String>) -> Routed {
        let session = self.find(id)?;
        let limit = query
            .get("limit")
            .and_then(|limit| limit.parse::<usize>().ok())
            .unwrap_or(100);
        let mut items: Vec<&ConversationItem> = session.snapshot.items.iter().collect();
        if query.get("order").map(String::as_str) == Some("desc") {
            items.reverse();
        }
        let start = query.get("after").map_or(0, |after| {
            items
                .iter()
                .position(|item| &item.id == after)
                .map_or(items.len(), |index| index.saturating_add(1))
        });
        let page: Vec<Value> = items
            .iter()
            .skip(start)
            .take(limit)
            .map(|item| serde_json::to_value(item).unwrap_or(Value::Null))
            .collect();
        let has_more = start.saturating_add(page.len()) < items.len();
        let id_at = |row: Option<&Value>| row.and_then(|row| row.get("id")).cloned();
        Ok((
            200,
            json!({
                "object": "list",
                "first_id": id_at(page.first()),
                "last_id": id_at(page.last()),
                "has_more": has_more,
                "data": page,
            }),
        ))
    }

    fn patch(&mut self, id: &str, body: &Value) -> Routed {
        let fields = body.as_object().ok_or(Reject(422, "Expected an object"))?;
        if fields
            .keys()
            .any(|key| !PATCH_FIELDS.contains(&key.as_str()))
        {
            return Err(Reject(422, "Extra inputs are not permitted"));
        }
        let session = self.find(id)?;
        let level = permission(session);
        let only_pin = fields.len() == 1 && fields.contains_key("labels");
        if level < 2 && !(only_pin && level >= 1) {
            return Err(Reject(403, "You have read-only access to this session."));
        }
        if fields.contains_key("archived") && level < 4 {
            return Err(Reject(403, "Only the owner can archive this session."));
        }
        let Ok(Value::Object(mut object)) = serde_json::to_value(&session.snapshot) else {
            return Err(Reject(500, "Could not encode the session"));
        };
        for (key, value) in fields {
            match key.as_str() {
                "labels" => {
                    let updates = value
                        .as_object()
                        .ok_or(Reject(422, "labels must be an object"))?;
                    let labels = object
                        .entry("labels")
                        .or_insert_with(|| Value::Object(Map::new()));
                    let Value::Object(labels) = labels else {
                        return Err(Reject(500, "labels are not an object"));
                    };
                    for (label, text) in updates {
                        match text.as_str() {
                            Some("") => {
                                labels.remove(label);
                            }
                            Some(_) => {
                                labels.insert(label.clone(), text.clone());
                            }
                            None => return Err(Reject(422, "label values must be strings")),
                        }
                    }
                }
                "model_override" | "reasoning_effort" => {
                    object.insert(key.clone(), clearable(value)?);
                }
                // A harness confirms a switched mode through its label.
                "permission_mode" | "approval_mode" => {
                    let label = if key == "permission_mode" {
                        PERMISSION_MODE_LABEL
                    } else {
                        APPROVAL_MODE_LABEL
                    };
                    let labels = object
                        .entry("labels")
                        .or_insert_with(|| Value::Object(Map::new()));
                    let Value::Object(labels) = labels else {
                        return Err(Reject(500, "labels are not an object"));
                    };
                    labels.insert(label.to_owned(), value.clone());
                }
                _ => {
                    object.insert(key.clone(), value.clone());
                }
            }
        }
        let snapshot = SessionSnapshot::from_value(Value::Object(object))
            .map_err(|_| Reject(422, "Invalid update"))?;
        let session = self.find_mut(id)?;
        session.snapshot = snapshot;
        session.revision = session.revision.saturating_add(1);
        Ok((200, snapshot_json(session, false)))
    }

    fn delete(&mut self, id: &str) -> Routed {
        if permission(self.find(id)?) < 4 {
            return Err(Reject(403, "Only the owner can delete this session."));
        }
        self.sessions.retain(|session| session.snapshot.id != id);
        self.replies.remove(id);
        self.reads.remove(id);
        Ok((200, json!({"deleted": true})))
    }

    fn event(&mut self, id: &str, body: &Value) -> Routed {
        let session = self.find(id)?;
        if permission(session) < 2 {
            return Err(Reject(403, "You have read-only access to this session."));
        }
        match body.get("type").and_then(Value::as_str) {
            Some("message") => self.message(id, body),
            Some("interrupt") => {
                self.interrupt(id)?;
                Ok((202, json!({"queued": false})))
            }
            _ => Err(Reject(400, "Unsupported event type")),
        }
    }

    fn message(&mut self, id: &str, body: &Value) -> Routed {
        let session = self.find(id)?;
        if session.snapshot.archived.value() == Some(&true) {
            return Err(Reject(
                409,
                "Restore this session before sending a message.",
            ));
        }
        if !session.snapshot.pending_elicitations.is_empty() {
            return Err(Reject(
                409,
                "Respond to the pending request before sending a message.",
            ));
        }
        if self.replies.contains_key(id) {
            return Err(Reject(
                409,
                "Wait for the reply or stop it before sending another message.",
            ));
        }
        let content = body
            .get("data")
            .and_then(|data| data.get("content"))
            .and_then(Value::as_array)
            .ok_or(Reject(400, "A message needs content"))?;
        let text = content
            .iter()
            .filter(|part| part.get("type").and_then(Value::as_str) == Some("input_text"))
            .filter_map(|part| part.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n");
        let text = text.trim();
        let mut parts: Vec<Value> = content
            .iter()
            .filter(|part| part.get("type").and_then(Value::as_str) != Some("input_text"))
            .cloned()
            .collect();
        if text.is_empty() && parts.is_empty() {
            return Err(Reject(400, "Write a message before sending."));
        }
        if !text.is_empty() {
            parts.push(json!({"type": "input_text", "text": text}));
        }
        let sequence = self.allocate();
        let user_id = format!("{id}-user-{sequence}");
        let reply_id = format!("{id}-reply-{sequence}");
        let now = self.now;
        let user = ConversationItem::from_value(json!({
            "id": user_id, "type": "message", "role": "user", "status": "completed",
            "created_at": now, "content": parts,
        }))
        .map_err(|_| Reject(400, "Invalid message content"))?;
        let reply = ConversationItem::from_value(json!({
            "id": reply_id, "type": "message", "role": "assistant", "status": "in_progress",
            "created_at": now, "content": [],
        }))
        .map_err(|_| Reject(500, "Could not start the reply"))?;
        let session = self.find_mut(id)?;
        session.snapshot.items.push(user);
        session.snapshot.items.push(reply);
        session.snapshot.status = SessionStatus::Running;
        session.snapshot.updated_at = Field::Present(now);
        session.revision = session.revision.saturating_add(1);
        let (reply_text, ticks_per_word) = if text.to_lowercase().contains("in detail") {
            (DEMO_DETAILED_REPLY_TEXT, DETAILED_REPLY_TICKS_PER_WORD)
        } else {
            (DEMO_REPLY_TEXT, 1)
        };
        self.replies.insert(
            id.to_owned(),
            ActiveReply {
                item_id: reply_id,
                words_sent: 0,
                text: reply_text,
                ticks_per_word,
                idle_ticks: 0,
            },
        );
        Ok((202, json!({"queued": true, "item_id": user_id})))
    }

    fn interrupt(&mut self, id: &str) -> Result<(), Reject> {
        let Some(reply) = self.replies.remove(id) else {
            return Ok(());
        };
        let now = self.now;
        let session = self.find_mut(id)?;
        if let Some(item) = session
            .snapshot
            .items
            .iter_mut()
            .find(|item| item.id == reply.item_id)
        {
            append_text(item, REPLY_STOPPED);
            item.status = Some(ItemStatus::Incomplete);
        }
        session.snapshot.status = SessionStatus::Idle;
        session.snapshot.updated_at = Field::Present(now);
        session.revision = session.revision.saturating_add(1);
        Ok(())
    }

    fn resolve(&mut self, id: &str, decision_id: &str, body: &Value) -> Routed {
        let session = self.find(id)?;
        if permission(session) < 2 {
            return Err(Reject(403, "You have read-only access to this session."));
        }
        let request = session
            .snapshot
            .pending_elicitations
            .iter()
            .find(|request| request.elicitation_id == decision_id)
            .ok_or(Reject(404, "This request is no longer available."))?;
        let action = body.get("action").and_then(Value::as_str);
        let content = body.get("content").and_then(Value::as_object);
        let properties = request
            .params
            .requested_schema
            .as_ref()
            .and_then(|schema| schema.get("properties"))
            .and_then(Value::as_object);
        let valid = match (action, properties) {
            (Some("decline" | "cancel"), _) => true,
            (Some("accept"), None) => content.is_none_or(Map::is_empty),
            (Some("accept"), Some(properties)) if properties.is_empty() => {
                content.is_none_or(Map::is_empty)
            }
            (Some("accept"), Some(properties)) => content.is_some_and(|content| {
                !content.is_empty()
                    && content.iter().all(|(key, value)| {
                        properties.get(key).is_some_and(|property| {
                            property
                                .get("enum")
                                .and_then(Value::as_array)
                                .is_none_or(|options| options.contains(value))
                        })
                    })
            }),
            _ => false,
        };
        if !valid {
            return Err(Reject(422, "Choose a valid response for this request."));
        }
        let now = self.now;
        let session = self.find_mut(id)?;
        session
            .snapshot
            .pending_elicitations
            .retain(|request| request.elicitation_id != decision_id);
        session.snapshot.updated_at = Field::Present(now);
        session.revision = session.revision.saturating_add(1);
        Ok((202, json!({"queued": false})))
    }

    fn create(&mut self, body: &Value) -> Routed {
        let agent_id = body
            .get("agent_id")
            .and_then(Value::as_str)
            .ok_or(Reject(422, "agent_id is required"))?;
        let agent = demo_agents()
            .into_iter()
            .find(|agent| agent.id == agent_id)
            .ok_or(Reject(400, "Unknown agent"))?;
        if body.get("host_id").and_then(Value::as_str) != Some(DEMO_HOST_ID) {
            return Err(Reject(400, "Unknown host"));
        }
        let title = body
            .get("title")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|title| !title.is_empty())
            .unwrap_or(DEFAULT_TITLE);
        let sequence = self.allocate();
        let id = format!("demo-session-{sequence}");
        let now = self.now;
        let mut object = json!({
            "id": id,
            "status": "idle",
            "created_at": now,
            "updated_at": now,
            "title": title,
            "workspace": body.get("workspace").and_then(Value::as_str).unwrap_or("/demo"),
            "agent_name": agent.name,
            "labels": {},
            "archived": false,
            "permission_level": 4,
            "items": [],
            "pending_elicitations": [],
        });
        if let Value::Object(fields) = &mut object {
            configure_snapshot(fields);
            fields.insert("agent_id".into(), json!(agent.id));
            let harness = agent.harness.unwrap_or_default();
            fields.insert("harness".into(), json!(harness));
            if let Some(Value::Object(labels)) = fields.get_mut("labels") {
                labels.insert("omnigent.wrapper".into(), json!(wrapper_for(&harness)));
            }
            if let Some(model) = body.get("model_override") {
                fields.insert("model_override".into(), model.clone());
            }
            // The mode a session launches in reaches it through these arguments.
            if let Some(args) = body.get("terminal_launch_args") {
                fields.insert("terminal_launch_args".into(), args.clone());
            }
        }
        let snapshot = SessionSnapshot::from_value(object)
            .map_err(|_| Reject(500, "Could not create the session"))?;
        let session = WorkspaceSession {
            revision: 1,
            snapshot,
        };
        let response = snapshot_json(&session, false);
        self.sessions.insert(0, session);
        Ok((201, response))
    }

    fn switch_agent(&mut self, id: &str, body: &Value) -> Routed {
        let session = self.find(id)?;
        if permission(session) < 2 {
            return Err(Reject(403, "You have read-only access to this session."));
        }
        let target = body
            .get("agent_id")
            .and_then(Value::as_str)
            .and_then(|agent_id| demo_agents().into_iter().find(|agent| agent.id == agent_id))
            .ok_or(Reject(400, "Unknown agent"))?;
        let Ok(Value::Object(mut object)) = serde_json::to_value(&session.snapshot) else {
            return Err(Reject(500, "Could not encode the session"));
        };
        let harness = target.harness.clone().unwrap_or_default();
        object.insert("agent_id".into(), json!(target.id));
        object.insert("agent_name".into(), json!(target.name));
        object.insert("harness".into(), json!(harness));
        object.insert("model_override".into(), Value::Null);
        object.insert("reasoning_effort".into(), Value::Null);
        if let Some(Value::Object(labels)) = object.get_mut("labels") {
            labels.insert("omnigent.wrapper".into(), json!(wrapper_for(&harness)));
        }
        let snapshot = SessionSnapshot::from_value(Value::Object(object))
            .map_err(|_| Reject(500, "Could not switch"))?;
        let session = self.find_mut(id)?;
        session.snapshot = snapshot;
        session.revision = session.revision.saturating_add(1);
        Ok((200, snapshot_json(session, false)))
    }
}

/// Ids of every session in `workspace`, in order (for tests and previews).
#[must_use]
pub fn session_ids(workspace: &Workspace) -> Vec<String> {
    workspace
        .sessions
        .iter()
        .map(|session| session.snapshot.id.clone())
        .collect()
}

/// Every item id of every session, for collision checks.
#[must_use]
pub fn item_ids(workspace: &Workspace) -> BTreeSet<String> {
    workspace
        .sessions
        .iter()
        .flat_map(|session| session.snapshot.items.iter().map(|item| item.id.clone()))
        .collect()
}

#[cfg(test)]
#[path = "demo_tests.rs"]
mod tests;
