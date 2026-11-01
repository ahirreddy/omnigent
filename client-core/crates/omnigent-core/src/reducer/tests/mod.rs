//! Reducer tests: ports of the `NativeLab` reducer suites plus `insta` snapshots of the recorded
//! real-server fixtures.
//!
//! Every event goes through [`Harness`], which also applies the returned row ops to a mirror of the
//! previously published rows and checks it equals the new rows: the ops contract a host store
//! relies on is verified on every fixture line.

mod event_parity;
mod hierarchy;
mod interrupt_marker;
mod live_reducer;
mod ops;
mod presentation;
mod reconciliation;
mod recorded;

use std::fmt::Write as _;

use serde_json::Value;

use super::{
    ChangeSet, ConversationSnapshot, Decision, EventSection, LiveReducer, Outcome, ReducerError,
    Row, RowRole, SessionHeader, apply_row_ops, display_text,
};

/// The text of `client-core/fixtures/<path>`.
pub(crate) fn fixture_text(path: &str) -> String {
    let full = format!("{}/../../fixtures/{path}", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(&full).unwrap_or_else(|error| panic!("reading {full}: {error}"))
}

/// A `.json` fixture.
pub(crate) fn fixture(path: &str) -> Value {
    serde_json::from_str(&fixture_text(path)).unwrap_or_else(|error| panic!("{path}: {error}"))
}

/// The values of a `.jsonl` fixture, one per non-empty line.
pub(crate) fn fixture_lines(path: &str) -> Vec<Value> {
    fixture_text(path)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| serde_json::from_str(line).unwrap_or_else(|error| panic!("{path}: {error}")))
        .collect()
}

/// The event lines of `fixtures/events/<name>`.
pub(crate) fn events(name: &str) -> Vec<Value> {
    fixture_lines(&format!("events/{name}"))
}

/// The `data` payloads of the SSE frames in `fixtures/sse/<name>`.
pub(crate) fn sse_data(name: &str) -> Vec<Value> {
    fixture_lines(&format!("sse/{name}"))
        .into_iter()
        .map(|frame| frame["data"].clone())
        .collect()
}

/// Parses inline JSON.
pub(crate) fn json(text: &str) -> Value {
    serde_json::from_str(text).unwrap_or_else(|error| panic!("{text}: {error}"))
}

/// A header like the `NativeLab` tests' `SessionSummary(id:title:preview:permissionLevel: 4)`.
pub(crate) fn header(id: &str) -> SessionHeader {
    let mut header = SessionHeader::new(id, "Session");
    header.permission_level = Some(4);
    header
}

/// A conversation with `rows`.
pub(crate) fn conversation(id: &str, rows: Vec<Row>) -> ConversationSnapshot {
    let mut snapshot = ConversationSnapshot::new(header(id));
    snapshot.revision = 1;
    snapshot.rows = rows;
    snapshot
}

/// A plain user row.
pub(crate) fn user(id: &str, text: &str) -> Row {
    Row::text(id, RowRole::User, text)
}

/// A plain assistant row.
pub(crate) fn assistant(id: &str, text: &str) -> Row {
    Row::text(id, RowRole::Assistant, text)
}

/// Drives a reducer and checks the published change sets against a mirror.
pub(crate) struct Harness {
    pub(crate) reducer: LiveReducer,
    rows: Vec<Row>,
    header: SessionHeader,
    decisions: Vec<Decision>,
    sections: Vec<EventSection>,
}

impl Harness {
    pub(crate) fn new(id: &str) -> Self {
        Self::from_snapshot(conversation(id, Vec::new()))
    }

    pub(crate) fn with_rows(id: &str, rows: Vec<Row>) -> Self {
        Self::from_snapshot(conversation(id, rows))
    }

    pub(crate) fn from_snapshot(snapshot: ConversationSnapshot) -> Self {
        let reducer = LiveReducer::new(snapshot);
        Self {
            rows: reducer.snapshot().rows.clone(),
            header: reducer.snapshot().header.clone(),
            decisions: reducer.snapshot().decisions.clone(),
            sections: reducer.sections().to_vec(),
            reducer,
        }
    }

    pub(crate) fn snapshot(&self) -> &ConversationSnapshot {
        self.reducer.snapshot()
    }

    /// Checks `changes` turn the mirror into the reducer's current state.
    pub(crate) fn check(&mut self, changes: &ChangeSet) {
        apply_row_ops(&mut self.rows, &changes.rows).expect("row ops apply");
        assert_eq!(
            self.rows,
            self.snapshot().rows,
            "row ops reproduce the rows"
        );
        if let Some(header) = &changes.header {
            self.header = header.clone();
        }
        assert_eq!(
            self.header,
            self.snapshot().header,
            "header change reported"
        );
        if let Some(decisions) = &changes.decisions {
            self.decisions.clone_from(decisions);
        }
        assert_eq!(
            self.decisions,
            self.snapshot().decisions,
            "decision change reported"
        );
        if let Some(sections) = &changes.sections {
            self.sections.clone_from(sections);
        }
        assert_eq!(self.sections, super::sections(&self.snapshot().event_state));
    }

    /// Applies an event payload that must decode and apply.
    pub(crate) fn send(&mut self, value: Value) -> Outcome {
        let text = value.to_string();
        let outcome = self
            .reducer
            .apply_value(value)
            .unwrap_or_else(|error| panic!("{text}: {error}"));
        self.check(&outcome.changes);
        outcome
    }

    /// Applies inline JSON that must decode and apply.
    pub(crate) fn send_json(&mut self, text: &str) -> Outcome {
        self.send(json(text))
    }

    /// Applies an event payload that may fail; a failure must leave the state unchanged.
    pub(crate) fn try_send(&mut self, value: Value) -> Result<Outcome, ReducerError> {
        let before = self.snapshot().clone();
        match self.reducer.apply_value(value) {
            Ok(outcome) => {
                self.check(&outcome.changes);
                Ok(outcome)
            }
            Err(error) => {
                assert_eq!(*self.snapshot(), before, "a failed event changes nothing");
                Err(error)
            }
        }
    }

    /// Applies every line, in order.
    pub(crate) fn send_all(&mut self, values: &[Value]) -> Vec<Outcome> {
        values
            .iter()
            .map(|value| self.send(value.clone()))
            .collect()
    }

    /// Reconciles with an authoritative snapshot and checks the reported changes.
    pub(crate) fn reconcile(&mut self, authoritative: ConversationSnapshot) -> ChangeSet {
        let changes = self.reducer.reconcile(authoritative);
        self.check(&changes);
        changes
    }

    pub(crate) fn ids(&self) -> Vec<&str> {
        self.snapshot()
            .rows
            .iter()
            .map(|row| row.id.as_str())
            .collect()
    }

    pub(crate) fn texts(&self) -> Vec<&str> {
        self.snapshot()
            .rows
            .iter()
            .map(|row| row.text.as_str())
            .collect()
    }

    pub(crate) fn assistant_texts(&self) -> Vec<&str> {
        self.snapshot()
            .rows
            .iter()
            .filter(|row| row.role == RowRole::Assistant)
            .map(|row| row.text.as_str())
            .collect()
    }

    pub(crate) fn last(&self) -> &Row {
        self.snapshot().rows.last().expect("a row")
    }

    pub(crate) fn pending_ids(&self) -> Vec<&str> {
        self.snapshot()
            .pending_decisions()
            .map(|decision| decision.id.as_str())
            .collect()
    }

    pub(crate) fn all_display(&self) -> String {
        self.snapshot()
            .rows
            .iter()
            .map(display_text)
            .collect::<Vec<_>>()
            .join("\n")
    }
}

fn render_row(out: &mut String, row: &Row) {
    let mut flags = Vec::new();
    if row.is_streaming {
        flags.push("streaming".to_owned());
    }
    if row.interrupted {
        flags.push("interrupted".to_owned());
    }
    if let Some(response) = &row.response_id {
        flags.push(format!("response={response}"));
    }
    if let Some(call) = &row.call_id {
        flags.push(format!("call={call}"));
    }
    write!(out, "- [{}] {}", row.role.as_str(), row.id).unwrap();
    for flag in &flags {
        write!(out, " {flag}").unwrap();
    }
    out.push('\n');
    writeln!(out, "    text: {:?}", row.text).unwrap();
    if let Some(activity) = &row.activity {
        writeln!(
            out,
            "    activity: {} {:?} / {:?} status={:?}",
            activity.kind.as_str(),
            activity.title,
            activity.summary,
            activity.status
        )
        .unwrap();
        for detail in &activity.details {
            writeln!(
                out,
                "      {} {:?}: {:?}",
                detail.id, detail.title, detail.text
            )
            .unwrap();
        }
    }
    for attachment in &row.attachments {
        writeln!(
            out,
            "    attachment: {} {} {:?} ref={:?}",
            attachment.id,
            attachment.kind.as_str(),
            attachment.title,
            attachment.reference
        )
        .unwrap();
    }
}

/// A stable text rendering of a conversation for `insta` snapshots.
pub(crate) fn render(snapshot: &ConversationSnapshot) -> String {
    let mut out = String::new();
    let header = &snapshot.header;
    writeln!(
        out,
        "session {} \"{}\" status={} read_only={} failure={:?}",
        header.id,
        header.title,
        header.status.as_str(),
        header.read_only,
        header.failure_message
    )
    .unwrap();
    for row in &snapshot.rows {
        render_row(&mut out, row);
    }
    for decision in &snapshot.decisions {
        writeln!(
            out,
            "decision {} target={} answered={}",
            decision.id, decision.target_session_id, decision.answered
        )
        .unwrap();
    }
    for section in super::sections(&snapshot.event_state) {
        writeln!(
            out,
            "section {} {:?}: {:?}",
            section.id, section.title, section.summary
        )
        .unwrap();
        for detail in &section.details {
            writeln!(out, "  {} {:?}: {:?}", detail.id, detail.title, detail.text).unwrap();
        }
    }
    out
}

const ACTIVITY_KINDS: [super::ActivityKind; 17] = {
    use super::ActivityKind as K;
    [
        K::ToolCall,
        K::ToolResult,
        K::NativeTool,
        K::Reasoning,
        K::Compaction,
        K::Command,
        K::Terminal,
        K::Routing,
        K::Resource,
        K::Error,
        K::Unknown,
        K::Retry,
        K::File,
        K::Policy,
        K::ClientTask,
        K::Browser,
        K::Sidechat,
    ]
};

fn swift_string(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_owned)
}

fn swift_row(value: &Value) -> Row {
    let role = match value["role"].as_str() {
        Some("user") => RowRole::User,
        Some("assistant") => RowRole::Assistant,
        _ => RowRole::Tool,
    };
    let mut row = Row::text(
        swift_string(value, "id").expect("id"),
        role,
        swift_string(value, "text").unwrap_or_default(),
    );
    row.is_streaming = value["isStreaming"].as_bool().unwrap_or_default();
    row.interrupted = value["interrupted"].as_bool().unwrap_or_default();
    row.call_id = swift_string(value, "callID");
    row.response_id = swift_string(value, "responseID");
    row.author = swift_string(value, "author");
    row.agent = swift_string(value, "agent");
    if let Some(activity) = value
        .get("activity")
        .filter(|activity| activity.is_object())
    {
        let kind = activity["kind"].as_str().expect("kind");
        row.activity = Some(super::Activity {
            kind: *ACTIVITY_KINDS
                .iter()
                .find(|candidate| candidate.as_str() == kind)
                .expect("known kind"),
            title: swift_string(activity, "title").unwrap_or_default(),
            summary: swift_string(activity, "summary").unwrap_or_default(),
            status: swift_string(activity, "status"),
            details: activity["details"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|detail| {
                    super::DetailSection::new(
                        detail["id"].as_str().unwrap_or_default(),
                        detail["title"].as_str().unwrap_or_default(),
                        detail["text"].as_str().unwrap_or_default(),
                        detail["isCode"].as_bool().unwrap_or_default(),
                    )
                })
                .collect(),
        });
    }
    for attachment in value["attachments"].as_array().into_iter().flatten() {
        row.attachments.push(super::Attachment {
            id: swift_string(attachment, "id").unwrap_or_default(),
            kind: match attachment["kind"].as_str() {
                Some("image") => super::AttachmentKind::Image,
                Some("audio") => super::AttachmentKind::Audio,
                Some("video") => super::AttachmentKind::Video,
                _ => super::AttachmentKind::File,
            },
            title: swift_string(attachment, "title").unwrap_or_default(),
            reference: swift_string(attachment, "reference"),
            mime_type: swift_string(attachment, "mimeType"),
            is_embedded: attachment["isEmbedded"].as_bool().unwrap_or_default(),
        });
    }
    row
}

/// A `NativeLab` `ConversationSnapshot` JSON encoding (`EventGallery--*`, `DemoFixtures--*`) as
/// reducer state. Decisions become elicitation requests whose message is the decision title.
pub(crate) fn swift_snapshot(value: &Value) -> ConversationSnapshot {
    use omnigent_protocol::{ElicitationRequest, FromWire};
    let session = &value["session"];
    let id = swift_string(session, "id").expect("session id");
    let mut header = SessionHeader::new(
        id.clone(),
        swift_string(session, "title").unwrap_or_default(),
    );
    header.status = match session["status"].as_str() {
        Some("running") => super::TurnStatus::Running,
        Some("needsResponse") => super::TurnStatus::NeedsResponse,
        _ => super::TurnStatus::Idle,
    };
    header.read_only = session["isReadOnly"].as_bool().unwrap_or_default();
    header.archived = session["isArchived"].as_bool().unwrap_or_default();
    header.failure_message = swift_string(session, "failureMessage");
    let decisions = value["decisions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|decision| {
            let request = ElicitationRequest::from_value(serde_json::json!({
                "elicitation_id": decision["id"],
                "params": {"message": decision["title"], "target_session_id": decision["targetSessionID"]},
            }))
            .expect("decision request");
            let mut decision_row = Decision::pending(request, &id);
            decision_row.answered = !decision["response"].is_null();
            decision_row
        })
        .collect();
    ConversationSnapshot {
        revision: value["revision"].as_u64().unwrap_or_default(),
        header,
        rows: value["messages"]
            .as_array()
            .into_iter()
            .flatten()
            .map(swift_row)
            .collect(),
        decisions,
        event_state: super::SessionEventState::default(),
    }
}
