//! Display-only events, activity previews and sparse session metadata.
//!
//! Ported from `NativeLab`'s `LiveEventPresentation.swift` (`applyPresentationEvent`,
//! `upsertActivity`, `presentError`, `presentUnknownEvent`), plus the server event types
//! `NativeLab` did not handle (wire-contract divergence D2).

use omnigent_protocol::ServerStreamEvent;
use omnigent_protocol::display;
use omnigent_protocol::events::{
    BrowserActionRequestEvent, ClientTaskCancelEvent, ErrorEvent, OutputFileDoneEvent,
    PolicyDeniedEvent, ReasoningDeltaEvent, RetryEvent, SessionBtwSidechatEvent,
    SessionChildSessionUpdatedEvent, SessionCreatedEvent, SessionResourceCreatedEvent,
    SessionUsageEvent, StreamErrorDetail, ToolOutputDeltaEvent,
};
use omnigent_protocol::sessions::{McpStartupStatus, SandboxStage, SandboxStatus};
use serde_json::{Map, Value};

use super::live::{Effects, LiveReducer};
use super::ops::ChangeSet;
use super::presentation::{
    SUMMARY_CHARS, TITLE_CHARS, bounded, fingerprint, prefix_chars, swift_number,
};
use super::state::{
    Activity, ActivityKind, Attachment, AttachmentKind, ChangedFiles, DetailSection, Row, RowRole,
    update_record,
};

/// Unknown-event rows kept at most; the oldest is dropped first.
const MAX_UNKNOWN_ROWS: usize = 80;
/// Bound of a streamed tool output buffer, in characters.
const TOOL_OUTPUT_CHARS: usize = 65_536;
/// Bound of a streamed reasoning summary, in characters.
const REASONING_CHARS: usize = 16_000;
/// Bound of a reasoning summary line, in characters.
const REASONING_SUMMARY_CHARS: usize = 180;
/// The event type `NativeLab` handled that the server no longer sends (D3).
const SKILLS_EVENT: &str = "session.skills";

fn changed() -> Effects {
    Effects {
        changed: true,
        ..Effects::default()
    }
}

/// One activity row to insert or replace.
struct ActivityUpdate<'a> {
    id: String,
    kind: ActivityKind,
    title: &'a str,
    summary: &'a str,
    status: Option<&'a str>,
    details: Vec<DetailSection>,
    call_id: Option<String>,
    streaming: bool,
    attachments: Option<Vec<Attachment>>,
}

impl<'a> ActivityUpdate<'a> {
    const fn new(id: String, kind: ActivityKind, title: &'a str, summary: &'a str) -> Self {
        Self {
            id,
            kind,
            title,
            summary,
            status: None,
            details: Vec::new(),
            call_id: None,
            streaming: false,
            attachments: None,
        }
    }

    const fn status(mut self, status: &'a str) -> Self {
        self.status = Some(status);
        self
    }

    fn details(mut self, details: Vec<DetailSection>) -> Self {
        self.details = details;
        self
    }

    const fn streaming(mut self) -> Self {
        self.streaming = true;
        self
    }
}

fn error_value(error: &StreamErrorDetail) -> Value {
    let mut fields = Map::new();
    fields.insert("code".to_owned(), Value::String(error.code.clone()));
    fields.insert("message".to_owned(), Value::String(error.message.clone()));
    if let Some(detail) = &error.detail {
        fields.insert("detail".to_owned(), Value::Object(detail.clone()));
    }
    Value::Object(fields)
}

impl LiveReducer {
    /// Events outside the response lifecycle: metadata, activity previews and placeholders.
    /// Heartbeats, `ui.open_file` and the `turn.*` edges change nothing (divergence D2).
    pub(super) fn apply_presentation_event(&mut self, event: &ServerStreamEvent) -> Effects {
        use ServerStreamEvent as E;
        match event {
            E::ToolOutputDelta(delta) => self.tool_output_delta(delta),
            E::ReasoningStarted(started) => self.reasoning(
                event.event_type(),
                started.item_id.as_deref(),
                None,
                ReasoningInput::Started,
            ),
            E::ReasoningTextDelta(delta) => {
                self.reasoning_delta(event.event_type(), delta, ReasoningInput::Private)
            }
            E::ReasoningSummaryTextDelta(delta) => self.reasoning_delta(
                event.event_type(),
                delta,
                ReasoningInput::Summary(&delta.delta),
            ),
            E::OutputFileDone(file) => self.output_file(file),
            E::Retry(retry) => self.retry(retry),
            E::Error(error) => self.response_error(error),
            E::PolicyDenied(denied) => self.policy_denied(denied),
            E::CompactionInProgress(_) => self.compaction(Compaction::InProgress, None),
            E::CompactionCompleted(done) => {
                self.compaction(Compaction::Completed, done.total_tokens)
            }
            E::CompactionFailed(_) => self.compaction(Compaction::Failed, None),
            E::ClientTaskCancel(cancel) => self.client_task(cancel),
            E::BrowserActionRequest(request) => self.browser(request),
            E::SessionBtwSidechat(sidechat) => self.sidechat(sidechat),
            E::Unknown { event_type, .. } if event_type == SKILLS_EVENT => Effects {
                changed: true,
                reconcile: true,
                ..Effects::default()
            },
            E::Unknown { event_type, raw } => self.present_unknown(event_type, raw),
            other => self.apply_metadata_event(other),
        }
    }

    /// Sparse session metadata events.
    fn apply_metadata_event(&mut self, event: &ServerStreamEvent) -> Effects {
        use ServerStreamEvent as E;
        match event {
            E::SessionUsage(usage) => self.usage(usage),
            E::SessionTodos(todos) => {
                self.state().todos = Some(todos.valid_todos());
                changed()
            }
            E::SessionPresence(presence) => {
                self.state().viewers = Some(presence.viewers.clone());
                changed()
            }
            E::SessionMcpStartup(startup) => {
                let mut servers = startup.servers.clone();
                servers
                    .retain(|_, server| !matches!(server.status, McpStartupStatus::Unknown { .. }));
                self.state().mcp_startup = Some(servers);
                changed()
            }
            E::SessionTerminalPending(pending) => {
                self.state().terminal_pending = Some(pending.pending);
                changed()
            }
            E::SessionSandboxStatus(sandbox) => {
                if matches!(sandbox.stage, SandboxStage::Unknown { .. }) {
                    return Effects::default();
                }
                self.state().sandbox = Some(SandboxStatus {
                    stage: sandbox.stage.clone(),
                    error: sandbox.error.clone(),
                    provider: sandbox.provider.clone(),
                    details: sandbox.details.clone(),
                });
                changed()
            }
            E::SessionCollaborationMode(mode) => {
                self.state().collaboration_mode = Some(mode.mode.clone());
                changed()
            }
            E::SessionPermissionMode(mode) => {
                self.state().permission_mode = Some(mode.permission_mode.clone());
                changed()
            }
            E::SessionCodexApprovalMode(mode) => {
                self.state().approval_mode = Some(mode.approval_mode.as_str().to_owned());
                changed()
            }
            E::SessionTitle(title) => {
                self.snap.header.title.clone_from(&title.title);
                changed()
            }
            other => self.apply_resource_event(other),
        }
    }

    /// Resource, child-session and changed-files events.
    fn apply_resource_event(&mut self, event: &ServerStreamEvent) -> Effects {
        use ServerStreamEvent as E;
        match event {
            E::SessionResourceCreated(created) => self.resource_created(created),
            E::SessionResourceDeleted(deleted) => {
                let state = self.state();
                update_record(&mut state.resources, &deleted.resource_id, None);
                if let Some(terminals) = &mut state.terminal_activity {
                    terminals.remove(&deleted.resource_id);
                }
                Effects {
                    changed: true,
                    reconcile: true,
                    ..Effects::default()
                }
            }
            E::SessionTerminalActivity(activity) => {
                if !activity.terminal_id.is_empty() {
                    self.state()
                        .terminal_activity
                        .get_or_insert_with(Default::default)
                        .insert(activity.terminal_id.clone());
                }
                changed()
            }
            E::SessionCreated(created) => self.child_created(created),
            E::SessionChildSessionUpdated(updated) => self.child_updated(updated),
            E::SessionSuperseded(superseded) => {
                if superseded.target_conversation_id.is_empty() {
                    return Effects::default();
                }
                self.state().superseded_by = Some(superseded.target_conversation_id.clone());
                Effects {
                    changed: true,
                    reconcile: true,
                    ..Effects::default()
                }
            }
            E::SessionChangedFilesInvalidated(invalidated) => {
                let environment = invalidated.environment_id().to_owned();
                if environment.is_empty() {
                    return Effects::default();
                }
                let state = self.state();
                update_record(
                    &mut state.changed_files,
                    &environment,
                    Some(ChangedFiles::Loading),
                );
                Effects {
                    changed: true,
                    changed_files_environment: Some(environment),
                    ..Effects::default()
                }
            }
            // Heartbeats, UI hints, turn edges; lifecycle, text, commits and decisions are
            // handled by `dispatch`.
            _ => Effects::default(),
        }
    }

    fn usage(&mut self, usage: &SessionUsageEvent) -> Effects {
        let invalid_cost = |cost: f64| !cost.is_finite() || cost < 0.0;
        let invalid_models = usage.usage_by_model.as_ref().is_some_and(|models| {
            models
                .values()
                .any(|model| model.total_cost_usd.is_some_and(invalid_cost))
        });
        if usage.context_window == Some(0)
            || usage.total_cost_usd.is_some_and(invalid_cost)
            || invalid_models
        {
            return Effects::default();
        }
        let state = self.state();
        if let Some(tokens) = usage.context_tokens {
            state.context_tokens = Some(tokens);
        }
        if let Some(window) = usage.context_window {
            state.context_window = Some(window);
        }
        if let Some(cost) = usage.total_cost_usd {
            state.total_cost_usd = Some(cost);
        }
        if let Some(models) = &usage.usage_by_model {
            state.usage_by_model = Some(models.clone());
        }
        changed()
    }

    fn resource_created(&mut self, created: &SessionResourceCreatedEvent) -> Effects {
        let Some(id) = created.resource_id().map(str::to_owned) else {
            return Effects::default();
        };
        if created
            .session_id()
            .is_some_and(|session| session != self.snap.header.id)
        {
            return Effects::default();
        }
        let state = self.state();
        update_record(&mut state.resources, &id, Some(created.resource.clone()));
        Effects {
            changed: true,
            reconcile: true,
            ..Effects::default()
        }
    }

    fn child_created(&mut self, created: &SessionCreatedEvent) -> Effects {
        if created.child_session_id.is_empty() {
            return Effects::default();
        }
        let mut update = Map::new();
        update.insert("status".to_owned(), Value::String("Created".to_owned()));
        let agent = created.agent_id.as_deref().unwrap_or("Subagent");
        update.insert("agent_name".to_owned(), Value::String(agent.to_owned()));
        self.merge_child(&created.child_session_id, update)
    }

    fn child_updated(&mut self, updated: &SessionChildSessionUpdatedEvent) -> Effects {
        if updated.child_session_id.is_empty() {
            return Effects::default();
        }
        self.merge_child(&updated.child_session_id, updated.child.clone())
    }

    fn merge_child(&mut self, id: &str, update: Map<String, Value>) -> Effects {
        let state = self.state();
        let mut child = state
            .children
            .as_ref()
            .and_then(|children| children.get(id))
            .cloned()
            .unwrap_or_default();
        child.extend(update);
        update_record(&mut state.children, id, Some(child));
        changed()
    }

    fn tool_output_delta(&mut self, delta: &ToolOutputDeltaEvent) -> Effects {
        if !self.accepts_response_deltas || delta.call_id.is_empty() {
            return Effects::default();
        }
        let id = format!("live:tool:{}:{}", self.scope_id(), delta.call_id);
        if self.retired_activity.contains(&id) || !self.accepts_chunk(delta.index, &id) {
            return Effects::default();
        }
        // A late replay must not resurrect output already committed to history.
        let committed = self.snap.rows.iter().any(|row| {
            !row.is_ephemeral()
                && row.call_id.as_deref() == Some(delta.call_id.as_str())
                && row.activity_kind() == Some(ActivityKind::ToolResult)
                && row.response_id == self.response_id
        });
        if committed {
            return Effects::default();
        }
        let buffered = self.activity_buffers.get(&id).cloned().unwrap_or_default();
        let output = prefix_chars(&(buffered + &delta.delta), TOOL_OUTPUT_CHARS);
        self.activity_buffers.insert(id.clone(), output.clone());
        let detail =
            DetailSection::new("output", "Output", display::safe_display_str(&output), true);
        let mut update = ActivityUpdate::new(
            id,
            ActivityKind::ToolResult,
            "Tool output",
            "Receiving output…",
        )
        .status("in_progress")
        .details(vec![detail])
        .streaming();
        update.call_id = Some(delta.call_id.clone());
        self.upsert_activity(update);
        changed()
    }

    fn reasoning_delta(
        &mut self,
        event_type: &str,
        delta: &ReasoningDeltaEvent,
        input: ReasoningInput<'_>,
    ) -> Effects {
        self.reasoning(event_type, delta.item_id.as_deref(), delta.index, input)
    }

    fn reasoning(
        &mut self,
        event_type: &str,
        source: Option<&str>,
        index: Option<u64>,
        input: ReasoningInput<'_>,
    ) -> Effects {
        if !self.accepts_response_deltas {
            return Effects::default();
        }
        let scope = self.scope_id();
        let id = source.map_or_else(
            || {
                self.active_reasoning
                    .clone()
                    .unwrap_or_else(|| format!("live:reasoning:{scope}:{}", self.activity_sequence))
            },
            |source| format!("live:reasoning:{scope}:item:{source}"),
        );
        if source.is_some_and(|source| self.position(source).is_some()) {
            return Effects::default();
        }
        if self.retired_activity.contains(&id)
            || !self.accepts_chunk(index, &format!("{id}:{event_type}"))
        {
            return Effects::default();
        }
        if self.active_reasoning.as_deref() != Some(id.as_str()) {
            self.close_reasoning_section();
            self.close_text_section();
            self.active_reasoning = Some(id.clone());
        }
        if let Some(source) = source {
            self.activity_item_ids.insert(id.clone(), source.to_owned());
        }
        // Raw or private reasoning is never substituted for an explicitly exposed summary.
        let mut summary = self.activity_buffers.get(&id).cloned().unwrap_or_default();
        match input {
            ReasoningInput::Summary(delta) => {
                summary = prefix_chars(&(summary + delta), REASONING_CHARS);
            }
            ReasoningInput::Started if !summary.is_empty() && !summary.ends_with("\n\n") => {
                summary.push_str("\n\n");
            }
            ReasoningInput::Started | ReasoningInput::Private => {}
        }
        self.activity_buffers.insert(id.clone(), summary.clone());
        let line = if summary.is_empty() {
            "Working…".to_owned()
        } else {
            prefix_chars(&summary, REASONING_SUMMARY_CHARS)
        };
        let details = if summary.is_empty() {
            Vec::new()
        } else {
            vec![DetailSection::new("summary", "Summary", summary, false)]
        };
        self.upsert_activity(
            ActivityUpdate::new(id, ActivityKind::Reasoning, "Reasoning", &line)
                .status("in_progress")
                .details(details)
                .streaming(),
        );
        changed()
    }

    fn output_file(&mut self, file: &OutputFileDoneEvent) -> Effects {
        if file.file_id.is_empty() {
            return Effects::default();
        }
        let title = file.filename.as_deref().unwrap_or("Generated file");
        let attachment = Attachment {
            id: file.file_id.clone(),
            kind: AttachmentKind::File,
            title: title.to_owned(),
            reference: Some(file.file_id.clone()),
            mime_type: file.content_type.clone(),
            is_embedded: false,
        };
        let mut update = ActivityUpdate::new(
            format!("event:file:{}", file.file_id),
            ActivityKind::File,
            "File ready",
            title,
        )
        .status("completed");
        update.attachments = Some(vec![attachment]);
        self.upsert_activity(update);
        changed()
    }

    fn retry(&mut self, retry: &RetryEvent) -> Effects {
        let delay = if retry.delay_seconds.is_finite() && retry.delay_seconds >= 0.0 {
            retry.delay_seconds
        } else {
            0.0
        };
        let summary = format!(
            "Attempt {} of {} · retry in {} seconds",
            retry.attempt,
            retry.max_attempts,
            swift_number(delay)
        );
        let target = retry.tool_name.as_deref();
        let title = format!("Retrying {}", target.unwrap_or("response"));
        let id = format!(
            "event:retry:{}:{}:{}",
            self.scope_id(),
            target.unwrap_or("model"),
            retry.attempt
        );
        let cause = display::safe_display_text(&error_value(&retry.error));
        let cause = if cause.is_empty() {
            "No details reported".to_owned()
        } else {
            cause
        };
        self.upsert_activity(
            ActivityUpdate::new(id, ActivityKind::Retry, &title, &summary)
                .status("retrying")
                .details(vec![DetailSection::new("error", "Cause", cause, false)]),
        );
        changed()
    }

    fn response_error(&mut self, error: &ErrorEvent) -> Effects {
        let message = error.error.message.clone();
        let source = error
            .source
            .as_ref()
            .map(|source| source.as_str().to_owned());
        self.present_error(&message, Some(&error.error.code), source.as_deref());
        self.snap.header.failure_message = Some(message.clone());
        Effects {
            changed: true,
            error: Some(message),
            ..Effects::default()
        }
    }

    fn policy_denied(&mut self, denied: &PolicyDeniedEvent) -> Effects {
        let reason = if denied.reason.is_empty() {
            "The server declined this action.".to_owned()
        } else {
            display::safe_display_str(&denied.reason)
        };
        let phase = display::safe_display_str(&denied.phase);
        let id = format!("event:policy:{}:{}", self.scope_id(), fingerprint(&reason));
        self.upsert_activity(
            ActivityUpdate::new(
                id,
                ActivityKind::Policy,
                "Action declined by policy",
                &reason,
            )
            .status("denied")
            .details(vec![DetailSection::new("phase", "Phase", phase, false)]),
        );
        self.snap.header.failure_message = Some(reason.clone());
        Effects {
            changed: true,
            reconcile: true,
            error: Some(reason),
            ..Effects::default()
        }
    }

    fn compaction(&mut self, stage: Compaction, total_tokens: Option<u64>) -> Effects {
        if let Some(tokens) = total_tokens {
            self.state().context_tokens = Some(tokens);
        }
        let (title, summary, status) = match stage {
            Compaction::InProgress => (
                "Compacting context",
                "Summarizing earlier context…",
                "in_progress",
            ),
            Compaction::Completed => (
                "Conversation compacted",
                "Earlier context was summarized.",
                "completed",
            ),
            Compaction::Failed => ("Compaction failed", "History is unchanged.", "failed"),
        };
        let details = if stage == Compaction::Failed {
            vec![DetailSection::new(
                "error",
                "Error",
                "Compaction failed.",
                false,
            )]
        } else {
            Vec::new()
        };
        let mut update = ActivityUpdate::new(
            format!("event:compaction:{}", self.scope_id()),
            ActivityKind::Compaction,
            title,
            summary,
        )
        .status(status)
        .details(details);
        update.streaming = stage == Compaction::InProgress;
        self.upsert_activity(update);
        Effects {
            changed: true,
            reconcile: stage != Compaction::InProgress,
            ..Effects::default()
        }
    }

    fn client_task(&mut self, cancel: &ClientTaskCancelEvent) -> Effects {
        if cancel.task_id.is_empty() {
            return Effects::default();
        }
        let mut update = ActivityUpdate::new(
            format!("event:client:{}", cancel.task_id),
            ActivityKind::ClientTask,
            "Client task cancelled",
            "The server cancelled this client-side task.",
        )
        .status("cancelled")
        .details(vec![DetailSection::new(
            "task",
            "Task ID",
            cancel.task_id.clone(),
            false,
        )]);
        update.call_id.clone_from(&cancel.call_id);
        self.upsert_activity(update);
        changed()
    }

    fn browser(&mut self, request: &BrowserActionRequestEvent) -> Effects {
        let title = format!("Desktop browser: {}", request.action);
        let args = display::safe_display_text(&Value::Object(request.args.clone()));
        self.upsert_activity(
            ActivityUpdate::new(
                format!("event:browser:{}", request.action_id),
                ActivityKind::Browser,
                &title,
                "Waiting for a desktop client with a browser to run this action.",
            )
            .status("desktop_required")
            .details(vec![DetailSection::new("request", "Request", args, false)]),
        );
        Effects {
            browser_action: Some(super::live::BrowserActionRequest {
                session_id: self.snap.header.id.clone(),
                action_id: request.action_id.clone(),
                action: request.action.clone(),
                args: request.args.clone(),
            }),
            ..changed()
        }
    }

    fn sidechat(&mut self, sidechat: &SessionBtwSidechatEvent) -> Effects {
        let question = display::safe_display_str(&sidechat.question);
        let mut answer = display::safe_display_str(&sidechat.answer);
        if sidechat.truncated {
            answer.push_str("\n[Answer truncated]");
        }
        let id = format!(
            "event:sidechat:{}:{}",
            self.scope_id(),
            fingerprint(&question)
        );
        self.upsert_activity(
            ActivityUpdate::new(id, ActivityKind::Sidechat, "Side question", &question)
                .status("completed")
                .details(vec![
                    DetailSection::new("question", "Question", question.clone(), false),
                    DetailSection::new("answer", "Answer", answer, false),
                ]),
        );
        changed()
    }

    /// An event type this client does not know: a bounded, sanitised placeholder row.
    fn present_unknown(&mut self, event_type: &str, raw: &Value) -> Effects {
        let text = display::safe_display_text(raw);
        let id = format!(
            "event:unknown:{}:{event_type}:{}",
            self.scope_id(),
            fingerprint(&text)
        );
        let source = raw
            .get("item_id")
            .or_else(|| raw.get("id"))
            .and_then(Value::as_str);
        if let Some(source) = source {
            self.activity_item_ids.insert(id.clone(), source.to_owned());
        }
        let committed = self
            .activity_item_ids
            .get(&id)
            .is_some_and(|source| self.position(source).is_some());
        if committed {
            return Effects::default();
        }
        self.upsert_activity(
            ActivityUpdate::new(id, ActivityKind::Unknown, "Session event", event_type).details(
                vec![DetailSection::new("payload", "Event details", text, true)],
            ),
        );
        let unknown: Vec<usize> = self
            .snap
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| row.id.starts_with("event:unknown:"))
            .map(|(at, _)| at)
            .collect();
        if unknown.len() > MAX_UNKNOWN_ROWS
            && let Some(first) = unknown.first()
        {
            self.remove_row(*first);
        }
        changed()
    }

    /// A readable error row, unless the persisted error item is already shown.
    pub(super) fn present_error(
        &mut self,
        message: &str,
        code: Option<&str>,
        source: Option<&str>,
    ) {
        let id = format!(
            "event:error:{}:{}:{}",
            self.scope_id(),
            code.unwrap_or("unknown"),
            fingerprint(message)
        );
        let mut details = vec![DetailSection::new(
            "message",
            "Error",
            bounded(message, display::MAX_DISPLAY_CHARS),
            false,
        )];
        if let Some(code) = code {
            details.push(DetailSection::new(
                "code",
                "Code",
                bounded(code, TITLE_CHARS),
                true,
            ));
        }
        if let Some(source) = source {
            details.push(DetailSection::new(
                "source",
                "Source",
                bounded(source, TITLE_CHARS),
                false,
            ));
        }
        let mut preview = Row::text(id.clone(), RowRole::Tool, message);
        preview.activity = Some(Activity {
            kind: ActivityKind::Error,
            title: "Response error".to_owned(),
            summary: bounded(message, SUMMARY_CHARS),
            status: Some("failed".to_owned()),
            details: details.clone(),
        });
        preview.response_id.clone_from(&self.response_id);
        let shown = self
            .snap
            .rows
            .iter()
            .any(|row| !row.is_ephemeral() && self.matches_activity(&preview, row));
        if shown {
            return;
        }
        self.upsert_activity(
            ActivityUpdate::new(id, ActivityKind::Error, "Response error", message)
                .status("failed")
                .details(details),
        );
    }

    fn upsert_activity(&mut self, update: ActivityUpdate<'_>) {
        let title = bounded(update.title, TITLE_CHARS);
        let summary = bounded(update.summary, SUMMARY_CHARS);
        let mut row = Row::text(update.id, RowRole::Tool, format!("{title}\n{summary}"));
        row.is_streaming = update.streaming;
        row.call_id = update.call_id;
        row.response_id.clone_from(&self.response_id);
        row.activity = Some(Activity {
            kind: update.kind,
            title,
            summary,
            status: update.status.map(str::to_owned),
            details: update.details,
        });
        let Some(at) = self.position(&row.id) else {
            row.attachments = update.attachments.unwrap_or_default();
            self.push_row(row);
            return;
        };
        row.attachments = update.attachments.unwrap_or_else(|| {
            self.snap
                .rows
                .get(at)
                .map(|existing| existing.attachments.clone())
                .unwrap_or_default()
        });
        self.replace_row(at, row);
    }

    /// Records the result of a changed-files fetch for `environment`.
    pub fn set_changed_files(&mut self, environment: &str, files: ChangedFiles) -> ChangeSet {
        let checkpoint = self.checkpoint();
        let state = self.state();
        update_record(&mut state.changed_files, environment, Some(files));
        self.finish(&checkpoint)
    }
}

/// What a reasoning event contributes to the visible summary.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReasoningInput<'a> {
    /// `response.reasoning.started`: a paragraph break before the next summary.
    Started,
    /// `response.reasoning_text.delta`: private raw reasoning, never shown.
    Private,
    /// `response.reasoning_summary_text.delta`: public summary text.
    Summary(&'a str),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Compaction {
    InProgress,
    Completed,
    Failed,
}
