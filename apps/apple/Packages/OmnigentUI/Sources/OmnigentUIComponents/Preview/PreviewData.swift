import Foundation
import SwiftUI

// Sample data reads best as one long literal table.
// swiftlint:disable file_length type_body_length function_parameter_count

/// Sample view state for previews, the gallery and rendering tests. Covers every row kind,
/// every decision kind and permission variant, every composer state and the session list.
enum PreviewData {
  static let sessionID = "sess_7Hq2"
  static let now = Date(timeIntervalSince1970: 1_793_520_000)  // 2026-11-01 08:00 UTC

  // MARK: Themes

  /// A sample second theme that exercises the theme system until the web UI's named themes land.
  static let sampleTheme = OmnigentTheme(
    id: "sample-violet", name: "Sample Violet",
    light: ThemePalette(
      accent: Color(red: 0.45, green: 0.30, blue: 0.85), running: .teal,
      surfaceTint: Color(red: 0.45, green: 0.30, blue: 0.85)),
    dark: ThemePalette(
      accent: Color(red: 0.62, green: 0.50, blue: 1.0), running: .mint,
      surfaceTint: Color(red: 0.62, green: 0.50, blue: 1.0)))

  static let themes = OmnigentTheme.builtIn + [sampleTheme]

  // MARK: Settings

  static let models = [
    ModelOption(
      id: "gpt-5.2-codex", model: "gpt-5.2-codex", displayName: "GPT-5.2 Codex",
      defaultReasoningEffort: "medium", supportedReasoningEfforts: ["low", "medium", "high"],
      isDefault: true),
    ModelOption(
      id: "gpt-5.2", model: "gpt-5.2", displayName: "GPT-5.2",
      supportedReasoningEfforts: ["minimal", "low", "medium", "high"]),
    ModelOption(id: "o4-mini", displayName: "o4-mini", hidden: true),
  ]

  static let settings = SessionSettings(
    agentId: "agent_codex", harness: "codex-native", wrapper: "codex-native-ui",
    modelOverride: .value(value: "gpt-5.2-codex"), baseModel: "gpt-5.2",
    reasoningEffort: .value(value: "high"), modelOptions: models, hostId: "host_mbp",
    hostOnline: true, runnerOnline: true, runnerBound: true, routingMode: "on")

  static let header = SessionHeader(
    id: sessionID, title: "Refactor token refresh and add tests", status: .running,
    permissionLevel: 3, settings: settings)

  // MARK: Rows

  static let assistantMarkdown = """
    I refactored the refresh path so a single in-flight refresh is shared by every caller. \
    Here is what changed:

    ## Summary

    1. **`TokenManager::refresh`** now coalesces concurrent calls.
    2. Expired refresh tokens surface `AuthError::SessionExpired` instead of retrying.
    3. Added *property tests* for the backoff schedule.

    | File | Change | Lines |
    |:-----|:------:|------:|
    | `auth/refresh.rs` | Coalesce refreshes | +42 / -17 |
    | `auth/tests.rs` | New tests | +88 |
    | `auth/errors.rs` | New variant | +6 |

    ```rust
    pub async fn refresh(&self) -> Result<Tokens, AuthError> {
        let shared = self.in_flight.get_or_init(|| self.start_refresh());
        shared.clone().await
    }
    ```

    - [x] Coalesce refreshes
    - [x] Tests for expiry
    - [ ] Update the web client

    > Note: the old `retry_refresh` helper is gone; nothing else called it.

    See the [design note](https://github.com/omnigent-ai/omnigent) for background. \
    A `javascript:` [link](javascript:alert(1)) stays plain text.
    """

  static let patch = """
    *** Begin Patch
    *** Update File: client-core/crates/omnigent-core/src/auth/refresh.rs
    @@ impl TokenManager {
    -    pub async fn refresh(&self) -> Result<Tokens, AuthError> {
    -        self.retry_refresh(3).await
    -    }
    +    pub async fn refresh(&self) -> Result<Tokens, AuthError> {
    +        let shared = self.in_flight.get_or_init(|| self.start_refresh());
    +        shared.clone().await
    +    }
    *** End Patch
    """

  static func tool(
    _ id: String, kind: ActivityKind, title: String, summary: String, details: [DetailSection],
    callId: String, status: String? = "completed", isFailure: Bool = false,
    isStreaming: Bool = false
  ) -> Row {
    Row(
      id: id, role: .tool, text: summary, isStreaming: isStreaming,
      activity: Activity(
        kind: kind, title: title, summary: summary, status: status, details: details,
        isFailure: isFailure),
      callId: callId, responseId: "resp_1")
  }

  static func activity(
    _ id: String, _ kind: ActivityKind, title: String, summary: String = "",
    status: String? = nil, details: [DetailSection] = [], isFailure: Bool = false,
    isStreaming: Bool = false, isActivityOnly: Bool = false
  ) -> Row {
    Row(
      id: id, role: .tool, text: [title, summary].joined(separator: "\n"), isStreaming: isStreaming,
      activity: Activity(
        kind: kind, title: title, summary: summary, status: status, details: details,
        isFailure: isFailure),
      responseId: "resp_1", isActivityOnly: isActivityOnly)
  }

  static let rows: [Row] = [
    Row(
      id: "item_u1", role: .user,
      text:
        "Can you refactor the token refresh in auth/refresh.rs so concurrent callers share one refresh, and add tests? Show me a table of the changes.",
      attachments: [
        Attachment(
          id: "att_1", kind: .image, title: "refresh-race.png", reference: "file_9a1",
          mimeType: "image/png"),
        Attachment(
          id: "att_2", kind: .file, title: "auth-spec.pdf", reference: "file_9a2",
          mimeType: "application/pdf"),
      ], author: "Ahir"),
    activity(
      "item_r1", .reasoning, title: "Reasoning summary",
      summary:
        "The race happens because each caller starts its own refresh. A shared future fixes it; tests should cover expiry and concurrency.",
      details: [
        DetailSection(
          id: "summary", title: "Summary",
          text:
            "The race happens because each caller starts its own refresh. **A shared future** fixes it; tests should cover expiry and concurrency."
        )
      ]),
    activity(
      "item_route", .routing, title: "Using gpt-5.2-codex",
      summary: "Code edits with tests: picked the coding model.",
      details: [
        DetailSection(
          id: "rationale", title: "Rationale",
          text: "Code edits with tests: picked the coding model.")
      ]),
    tool(
      "item_c1", kind: .toolCall, title: "Read",
      summary: "{\"path\": \"client-core/crates/omnigent-core/src/auth/refresh.rs\"}",
      details: [
        DetailSection(
          id: "arguments", title: "Arguments",
          text: "{\n  \"path\": \"client-core/crates/omnigent-core/src/auth/refresh.rs\"\n}",
          isCode: true)
      ], callId: "call_1"),
    tool(
      "item_o1", kind: .toolResult, title: "Tool result",
      summary: "pub struct TokenManager { ... }",
      details: [
        DetailSection(
          id: "output", title: "Output",
          text: "pub struct TokenManager {\n    in_flight: OnceCell<Shared<Refresh>>,\n}",
          isCode: true)
      ], callId: "call_1"),
    tool(
      "item_c2", kind: .toolCall, title: "shell",
      summary: "{\"command\": \"cargo test -p omnigent-core auth\"}",
      details: [
        DetailSection(
          id: "arguments", title: "Arguments",
          text: "{\n  \"command\": \"cargo test -p omnigent-core auth\"\n}", isCode: true)
      ], callId: "call_2"),
    tool(
      "item_o2", kind: .toolResult, title: "Tool result",
      summary: "test result: FAILED. 41 passed; 1 failed",
      details: [
        DetailSection(
          id: "output", title: "Output",
          text:
            "running 42 tests\ntest auth::refresh::expired ... FAILED\n\nfailures:\n    auth::refresh::expired\n\ntest result: FAILED. 41 passed; 1 failed",
          isCode: true)
      ], callId: "call_2", status: "failed", isFailure: true),
    tool(
      "item_c3", kind: .toolCall, title: "apply_patch",
      summary: "{\"input\": \"*** Begin Patch ...\"}",
      details: [DetailSection(id: "arguments", title: "Arguments", text: patch, isCode: true)],
      callId: "call_3"),
    tool(
      "item_o3", kind: .toolResult, title: "Tool result", summary: "File change applied.",
      details: [
        DetailSection(id: "output", title: "Output", text: "File change applied.", isCode: true)
      ],
      callId: "call_3"),
    tool(
      "item_n1", kind: .nativeTool, title: "web_search", summary: "tokio OnceCell shared future",
      details: [
        DetailSection(
          id: "query", title: "Query", text: "tokio OnceCell shared future", isCode: false)
      ], callId: "call_4"),
    Row(
      id: "item_a1", role: .assistant, text: assistantMarkdown, responseId: "resp_1",
      agent: "Codex"),
    activity(
      "item_t1", .terminal, title: "Terminal command", summary: "git status --short",
      details: [
        DetailSection(id: "input", title: "Command", text: "git status --short", isCode: true)
      ]),
    activity(
      "item_t2", .terminal, title: "Terminal output",
      summary: " M client-core/crates/omnigent-core/src/auth/refresh.rs",
      details: [
        DetailSection(
          id: "stdout", title: "Standard output",
          text:
            " M client-core/crates/omnigent-core/src/auth/refresh.rs\n M client-core/crates/omnigent-core/src/auth/tests.rs\n?? client-core/crates/omnigent-core/src/auth/errors.rs",
          isCode: true),
        DetailSection(
          id: "stderr", title: "Standard error", text: "warning: CRLF will be replaced by LF",
          isCode: true),
      ]),
    activity(
      "item_cmd", .command, title: "Skill /review", summary: "/review auth",
      details: [
        DetailSection(id: "invocation", title: "Invocation", text: "/review auth", isCode: true),
        DetailSection(
          id: "output", title: "Output", text: "No blocking issues found.", isCode: true),
      ]),
    activity(
      "item_cmp", .compaction, title: "Context compacted",
      summary: "Earlier context was summarized for this session.",
      details: [
        DetailSection(
          id: "summary", title: "Summary", text: "Refactor in progress; tests failing on expiry."),
        DetailSection(id: "tokens", title: "Summary tokens", text: "1840"),
      ]),
    activity(
      "item_retry", .retry, title: "Retrying model call",
      summary: "Rate limited (429). Attempt 2 of 5 in 4 seconds.", status: "in_progress"),
    activity(
      "item_err", .error, title: "Response error",
      summary: "The provider returned 502 Bad Gateway.",
      status: "failed",
      details: [
        DetailSection(
          id: "message", title: "Error", text: "The provider returned 502 Bad Gateway."),
        DetailSection(id: "code", title: "Code", text: "upstream_error", isCode: true),
        DetailSection(id: "source", title: "Source", text: "provider"),
      ], isFailure: true),
    activity(
      "item_file", .file, title: "Generated report.md", summary: "Refactor notes, 3 KB",
      details: [
        DetailSection(id: "path", title: "Path", text: "/workspace/report.md", isCode: true)
      ]),
    activity(
      "item_policy", .policy, title: "Blocked by policy",
      summary: "Network access to pypi.org is not allowed in this workspace.", status: "denied",
      isFailure: true),
    activity(
      "item_task", .clientTask, title: "Open in Finder", summary: "The server cancelled this task.",
      status: "cancelled"),
    activity(
      "item_browser", .browser, title: "Navigate",
      summary: "https://docs.rs/tokio/latest/tokio/sync",
      status: "completed",
      details: [
        DetailSection(
          id: "url", title: "URL", text: "https://docs.rs/tokio/latest/tokio/sync", isCode: true)
      ]),
    activity(
      "item_side", .sidechat, title: "Side question",
      details: [
        DetailSection(
          id: "question", title: "Question", text: "Does OnceCell reset after an error?"),
        DetailSection(
          id: "answer", title: "Answer",
          text: "No. Use `take()` on failure so the **next** caller starts a fresh refresh."),
      ]),
    activity(
      "item_unknown", .unknown, title: "canvas_update",
      summary: "An item this app does not support yet.",
      details: [
        DetailSection(
          id: "payload", title: "Event details",
          text: "{\n  \"type\": \"canvas_update\",\n  \"nodes\": 4\n}",
          isCode: true)
      ]),
    Row(
      id: "item_u2", role: .user, text: "Here is the trace from the failing run.",
      activity: Activity(
        kind: .unknown, title: "Message content",
        summary: "Here is the trace from the failing run.",
        details: [
          DetailSection(
            id: "content-1", title: "input audio", text: "[audio, 12 s, not shown]", isCode: true)
        ]), author: "Ahir"),
    Row(
      id: "item_a2", role: .assistant,
      text: "Stopping here as asked. The expiry test still fails because", interrupted: true,
      agent: "Codex"),
    activity(
      "item_res", .resource, title: "Terminal attached", summary: "terminal_1", isActivityOnly: true
    ),
    Row(
      id: "live:response:resp_2:0", role: .assistant,
      text: "Re-running the expiry test with the fix applied. So far the shared refresh",
      isStreaming: true,
      agent: "Codex", isEphemeral: true),
  ]

  // MARK: Sections

  static let sections: [EventSection] = [
    EventSection(id: "status", title: "Session", summary: "Running"),
    EventSection(id: "permission", title: "Permission mode", summary: "Accept edits"),
    EventSection(
      id: "usage", title: "Usage", summary: "84200 context tokens",
      details: [
        DetailSection(id: "context_tokens", title: "Context tokens", text: "84200"),
        DetailSection(id: "context_window", title: "Context window", text: "128000"),
        DetailSection(id: "total_cost_usd", title: "Total cost (USD)", text: "0.42"),
        DetailSection(
          id: "usage_by_model", title: "Usage by model",
          text: "gpt-5.2-codex: input_tokens: 80100, output_tokens: 4100"),
      ]),
    EventSection(
      id: "todos", title: "Tasks", summary: "2 of 4 complete",
      details: [
        DetailSection(id: "todo-0", title: "Completed: Read refresh.rs", text: "Read refresh.rs"),
        DetailSection(
          id: "todo-1", title: "Completed: Coalesce refreshes", text: "Coalesce refreshes"),
        DetailSection(
          id: "todo-2", title: "In Progress: Fix the expiry test", text: "Fixing the expiry test"),
        DetailSection(
          id: "todo-3", title: "Pending: Update the web client", text: "Update the web client"),
      ]),
    EventSection(
      id: "presence", title: "Viewers", summary: "3 connected",
      details: [
        DetailSection(id: "viewer-0", title: "ahir.reddy", text: "Active"),
        DetailSection(id: "viewer-1", title: "ankit", text: "Active"),
        DetailSection(id: "viewer-2", title: "sam.lee", text: "Idle"),
      ]),
    EventSection(
      id: "mcp", title: "MCP servers", summary: "2 servers",
      details: [
        DetailSection(id: "github", title: "github", text: "ready"),
        DetailSection(id: "linear", title: "linear", text: "failed\nOAuth token expired"),
      ]),
    EventSection(
      id: "child-sess_c1", title: "Write auth tests", summary: "Running",
      details: [DetailSection(id: "id", title: "Session ID", text: "sess_c1")], sessionId: "sess_c1"
    ),
    EventSection(
      id: "child-sess_c2", title: "Review patch", summary: "Completed",
      details: [DetailSection(id: "id", title: "Session ID", text: "sess_c2")], sessionId: "sess_c2"
    ),
    EventSection(
      id: "files-default", title: "Changed files", summary: "3 files in default",
      details: [
        DetailSection(
          id: "file-0", title: "client-core/crates/omnigent-core/src/auth/refresh.rs",
          text: "modified"),
        DetailSection(
          id: "file-1", title: "client-core/crates/omnigent-core/src/auth/tests.rs",
          text: "modified"),
        DetailSection(
          id: "file-2", title: "client-core/crates/omnigent-core/src/auth/errors.rs", text: "added"),
      ]),
    EventSection(
      id: "resource-terminal_1", title: "Terminal", summary: "Terminal output received",
      details: [DetailSection(id: "cwd", title: "Cwd", text: "/workspace/omnigent", isCode: true)]),
  ]

  // MARK: Decisions

  static func card(
    _ id: String, title: String = "Approval requested", detail: String,
    kind: DecisionKind = .approval,
    permissions: PermissionOptions = PermissionOptions(), phase: String? = nil,
    policyName: String? = nil, answered: Bool = false, mirrored: Bool = false
  ) -> DecisionCard {
    DecisionCard(
      id: id, carryingSessionId: sessionID, targetSessionId: mirrored ? "sess_c1" : sessionID,
      title: title, detail: detail, kind: kind, permissions: permissions, phase: phase,
      policyName: policyName, answered: answered)
  }

  static let approval = card(
    "elic_approve",
    detail: "Codex wants to edit 3 files in client-core/crates/omnigent-core/src/auth.",
    permissions: PermissionOptions(
      allowAllEdits: true, permissionDirectories: ["/workspace/omnigent/client-core"],
      rememberLabel: "Edit"),
    policyName: "Edit files")

  static let codexCommand = card(
    "elic_codex", detail: "Run the auth test suite.",
    permissions: PermissionOptions(
      command: CommandApproval(
        command: "cargo test -p omnigent-core auth -- --nocapture", cwd: "/workspace/omnigent",
        reason: "Verify the expiry fix"),
      execPolicyAmendment: ["cargo", "test"], persistModes: [.session, .always]))

  static let antigravity = card(
    "elic_agy", detail: "Antigravity wants to run a terminal command.",
    permissions: PermissionOptions(
      antigravity: AntigravityPermission(
        actionDescription: "Run npm install in web/", alwaysAllowPattern: "npm install")),
    phase: "agy_permission", mirrored: true)

  static let planReview = card(
    "elic_plan", title: "Review the plan", detail: "",
    permissions: PermissionOptions(
      allowAllEdits: true, allowAutoMode: true,
      plan: """
        ## Plan

        1. Share one refresh future across callers.
        2. Map an expired refresh token to `SessionExpired`.
        3. Add tests for **expiry** and **concurrency**.
        """))

  static let choice = card(
    "elic_choice", title: "Response requested", detail: "Which branch should I push to?",
    kind: .choice(answerKey: "branch", options: ["main", "auth-refresh", "Create a new branch"]))

  static let formFields: [FormField] = [
    FormField(
      key: "title", title: "PR title", detail: "Shown on GitHub.", kind: .text, maxLength: 72),
    FormField(
      key: "reviewers", title: "Reviewers", kind: .integer, required: false, minimum: 0, maximum: 5),
    FormField(key: "draft", title: "Open as draft", kind: .boolean),
    FormField(
      key: "base", title: "Base branch", kind: .singleChoice,
      options: [
        FormOption(value: "main", detail: "The default branch"),
        FormOption(value: "release-2026.11", label: "release-2026.11"),
      ], allowsCustom: true),
    FormField(
      key: "labels", title: "Labels", kind: .multipleChoice, required: false,
      options: [
        FormOption(value: "auth"), FormOption(value: "tests"), FormOption(value: "client-core"),
      ],
      maxItems: 2),
    FormField(key: "token", title: "Signing token", kind: .text, required: false, isSecret: true),
  ]

  static let form = card(
    "elic_form", title: "Response requested", detail: "Fill in the pull request details.",
    kind: .form(fields: formFields))

  static let unsupported = card(
    "elic_url", title: "Approval requested", detail: "Authorize the Linear MCP server.",
    kind: .unsupported(
      reason:
        "Complete this request on its confirmation page. The session will update when the server receives your response.",
      externalUrl: "https://linear.app/oauth/authorize?client_id=omnigent"))

  static let answered = card(
    "elic_done", detail: "Delete the generated report.md?", answered: true)

  static let decisions = [
    approval, codexCommand, antigravity, planReview, choice, form, unsupported, answered,
  ]

  // MARK: Conversation

  static let conversation = ConversationViewState(
    revision: 42, header: header, rows: rows, decisions: [codexCommand, choice],
    sections: sections, hasMoreHistory: true, connectionStatus: "Connected")

  static let failedConversation = ConversationViewState(
    revision: 3,
    header: SessionHeader(
      id: "sess_fail", title: "Nightly dependency bump", status: .idle,
      failureMessage: "The provider rejected the request: invalid API key.", settings: settings),
    rows: [
      Row(id: "f_u1", role: .user, text: "Bump all Rust dependencies and run the tests.")
    ],
    errorMessage: "Lost connection to the server. Reconnecting in 4 seconds.")

  static let emptyConversation = ConversationViewState(
    header: SessionHeader(id: "sess_new", title: "New session", settings: settings))

  static func largeConversation(count: Int) -> ConversationViewState {
    var rows: [Row] = []
    rows.reserveCapacity(count)
    for index in 0..<count {
      switch index % 4 {
      case 0:
        rows.append(
          Row(
            id: "big_u\(index)", role: .user,
            text: "Question \(index): what changed in step \(index)?"))
      case 1:
        rows.append(
          tool(
            "big_c\(index)", kind: .toolCall, title: "Read",
            summary: "{\"path\": \"file\(index).rs\"}",
            details: [], callId: "big_call\(index)"))
      case 2:
        rows.append(
          tool(
            "big_o\(index)", kind: .toolResult, title: "Tool result", summary: "ok", details: [],
            callId: "big_call\(index - 1)"))
      default:
        rows.append(
          Row(
            id: "big_a\(index)", role: .assistant,
            text: "Step \(index) updated **\(index % 7) files**.", agent: "Codex"))
      }
    }
    return ConversationViewState(
      revision: UInt64(count), header: SessionHeader(id: "sess_big", title: "Long session"),
      rows: rows)
  }

  // MARK: Composer

  static let configuration = ComposerConfiguration(
    harness: "codex-native",
    harnessChoices: [
      HarnessChoice(id: "agent_codex", name: "Codex", harness: "codex-native"),
      HarnessChoice(id: "agent_claude", name: "Claude Code", harness: "claude-native"),
    ], selectedAgentId: "agent_codex", modelOptions: models, selectedModelId: "gpt-5.2-codex",
    selectedEffort: "high")

  static let composerIdle = ComposerViewState(configuration: configuration)
  static let composerRunning = ComposerViewState(isRunning: true, configuration: configuration)
  static let composerUnavailable = ComposerViewState(
    availability: .unavailable(
      reason: "Read-only access. Ask the owner for edit permission to send messages."),
    configuration: configuration)
  static let composerUncertain = ComposerViewState(
    delivery: .uncertain(
      message:
        "The server may have received your message, but confirmation was lost. Check the conversation before sending again."
    ),
    configuration: configuration)
  static let composerFailed = ComposerViewState(
    delivery: .failed(message: "The message was not sent: the server returned 503."),
    configuration: configuration)
  static let composerAttachments = ComposerViewState(
    delivery: .sending,
    attachments: [
      DraftAttachment(id: "d1", title: "trace.log", kind: .file, byteCount: 48_213, state: .ready),
      DraftAttachment(
        id: "d2", title: "screenshot.png", kind: .image, byteCount: 1_204_400,
        state: .uploading(progress: 0.4)),
      DraftAttachment(
        id: "d3", title: "archive.zip", kind: .file, byteCount: 104_857_600,
        state: .failed(message: "Too large: the limit is 25 MB.")),
    ], configuration: configuration)

  struct ComposerSample: Identifiable {
    let title: String
    let state: ComposerViewState
    let draft: String
    var id: String { title }
  }

  static let composerStates: [ComposerSample] = [
    ComposerSample(title: "Idle", state: composerIdle, draft: ""),
    ComposerSample(
      title: "Draft", state: composerIdle,
      draft: "Also add a test for the 401 path.\nAnd update the changelog."),
    ComposerSample(title: "Running", state: composerRunning, draft: ""),
    ComposerSample(title: "Unavailable", state: composerUnavailable, draft: ""),
    ComposerSample(
      title: "Uncertain delivery", state: composerUncertain, draft: "Retry the deployment"),
    ComposerSample(title: "Failed delivery", state: composerFailed, draft: "Retry the deployment"),
    ComposerSample(
      title: "Attachments", state: composerAttachments, draft: "See the attached trace."),
  ]

  // MARK: Session list

  static func summary(
    _ id: String, _ title: String, preview: String, status: SessionListStatus = .idle,
    hoursAgo: Double, agent: String = "Codex", workspace: String = "/workspace/omnigent",
    pinned: Bool = false, archived: Bool = false, readOnly: Bool = false, failure: String? = nil
  ) -> SessionSummary {
    SessionSummary(
      id: id, title: title, preview: preview, status: status, isReadOnly: readOnly,
      updatedAt: Int64(now.timeIntervalSince1970 - hoursAgo * 3600), workspace: workspace,
      agentName: agent, isPinned: pinned, isArchived: archived, failureMessage: failure)
  }

  static let sessions: [SessionSummary] = [
    summary(
      "sess_p1", "Release checklist", preview: "All checks green.", hoursAgo: 30, pinned: true),
    summary(
      sessionID, "Refactor token refresh and add tests", preview: "Re-running the expiry test",
      status: .running, hoursAgo: 0.1),
    summary(
      "sess_a2", "Fix flaky SSE reconnect test", preview: "Approval requested: run cargo test",
      status: .needsResponse, hoursAgo: 0.6, agent: "Claude Code"),
    summary(
      "sess_a3", "Nightly dependency bump", preview: "The provider rejected the request.",
      hoursAgo: 2, failure: "Invalid API key"),
    summary(
      "sess_a4", "Design review: inspector layout", preview: "Shared with you", hoursAgo: 5,
      agent: "Pi",
      readOnly: true),
    summary(
      "sess_y1", "Port session query to Rust", preview: "Done. 24 tests ported.", hoursAgo: 27),
    summary(
      "sess_w1", "Investigate memory growth in the runner", preview: "Heap profile attached.",
      hoursAgo: 80, agent: "Antigravity", workspace: "/srv/runner"),
    summary(
      "sess_m1", "Write onboarding doc", preview: "Draft ready for review.", hoursAgo: 24 * 12),
    summary(
      "sess_o1", "Spike: WASM build of the core", preview: "wasm32 check passes.", hoursAgo: 24 * 60
    ),
  ]

  static let sessionList = SessionListViewState(
    sessions: sessions, filter: .all, unreadIds: ["sess_a2", "sess_y1"],
    attentionCounts: ["sess_a2": 2],
    filterCounts: [.all: 9, .running: 1, .needsResponse: 1, .archived: 4],
    now: now)

  // MARK: New session

  static let catalog = CreationCatalog(
    hosts: [
      CreationHost(
        hostId: "host_mbp", name: "Ahir's MacBook Pro", status: "online",
        configuredHarnesses: ["codex-native": .ready, "claude-native": .needsAuthentication]),
      CreationHost(hostId: "host_ci", name: "CI runner", status: "offline"),
      CreationHost(
        hostId: "host_sbx", name: "Managed sandbox", status: "online", sandboxProvider: "modal"),
    ],
    agents: [
      CreationAgent(
        id: "agent_codex", name: "Codex", harness: "codex-native",
        description: "OpenAI Codex CLI on your host."),
      CreationAgent(id: "agent_claude", name: "Claude Code", harness: "claude-native"),
      CreationAgent(id: "agent_pi", name: "Pi", harness: "pi"),
    ])

  static let newSession = NewSessionViewState(
    catalog: .loaded(catalog),
    workspaces: .loaded([
      CreationWorkspace(path: "/Users/ahir/src/omnigent", name: "omnigent"),
      CreationWorkspace(path: "/Users/ahir/src/web", name: "web"),
    ]),
    models: .loaded(models))

  static func unavailableReason(_ selection: CreationSelection) -> String? {
    guard let host = catalog.hosts.first(where: { $0.hostId == selection.hostId }) else {
      return "Choose an existing host."
    }
    if host.sandboxProvider != nil { return "Managed sandbox creation is not available here." }
    if host.status != "online" { return "Connect this host before starting a session." }
    if selection.agentId.isEmpty { return "Choose a registered agent." }
    if selection.agentId == "agent_claude" { return "Sign in to this harness on the host first." }
    if !selection.workspace.hasPrefix("/") {
      return "Enter an absolute workspace path beginning with /."
    }
    return nil
  }

  /// A preview form validator standing in for the core's `DecisionForm::validate`.
  static func validate(_ card: DecisionCard, _ values: [String: ElicitationValue]) -> String? {
    guard case .form(let fields) = card.kind else { return nil }
    for field in fields {
      switch values[field.key] {
      case .text(let text):
        if let max = field.maxLength, UInt64(text.count) > max {
          return "\(field.title) can be at most \(max) characters."
        }
      case .integer(let value):
        if let max = field.maximum, Double(value) > max {
          return "\(field.title) can be at most \(Int(max))."
        }
      case .textList(let values):
        if let max = field.maxItems, UInt64(values.count) > max {
          return "Choose at most \(max) \(field.title.lowercased())."
        }
      default:
        continue
      }
    }
    return nil
  }
}

// swiftlint:enable file_length type_body_length function_parameter_count
