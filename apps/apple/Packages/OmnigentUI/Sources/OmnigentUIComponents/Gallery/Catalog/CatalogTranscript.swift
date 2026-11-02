import Foundation
import SwiftUI

/// Transcript: messages, tools, activity rows, banners, turn chrome and sub-agents.
enum TranscriptCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .transcript, "message", "Message Row",
        summary: "A user or assistant message with its actions, attachments and author.",
        systemImage: "text.bubble", canvas: .column(width: 820),
        keywords: ["bubble", "user", "assistant"],
        states: [
          message("user", "User", Row(id: "u", role: .user, text: "Looks good, ship it.")),
          message("assistant", "Assistant", PreviewData.rows[0].assistantSample),
          message(
            "streaming", "Streaming",
            Row(
              id: "s", role: .assistant, text: "Re-running the expiry test with the shared",
              isStreaming: true)),
          message(
            "interrupted", "Interrupted",
            Row(id: "i", role: .assistant, text: "Stopped.", interrupted: true)),
          message("attachments", "With attachments", PreviewData.rows[0]),
          message("long", "Long text", Row(id: "l", role: .user, text: CatalogSamples.longText)),
          message(
            "shared", "Shared session author",
            Row(id: "a", role: .user, text: "Can you also check the CI logs?", author: "Priya")),
        ]),
      .component(
        .transcript, "tools", "Tool Group",
        summary: "Consecutive tool calls folded into one group, with a diff when there is one.",
        systemImage: "wrench.and.screwdriver", canvas: .column(width: 820),
        keywords: ["tool call", "diff"],
        states: [
          CatalogState("group", "Completed group") {
            TranscriptSample(items: TranscriptSamples.tools)
          },
          CatalogState("running", "Running", note: "The last call has no result yet.") {
            TranscriptSample(items: TranscriptSamples.runningTools)
          },
          CatalogState("diff", "Diff") {
            DiffSample()
          },
        ]),
      .component(
        .transcript, "activity", "Activity Rows",
        summary:
          "Reasoning, terminal output, errors, retries, compaction, side chats and unknowns.",
        systemImage: "list.bullet.rectangle", canvas: .column(width: 820),
        keywords: ["reasoning", "error", "retry", "compaction", "unknown"],
        states: TranscriptSamples.activities.map { sample in
          CatalogState(sample.id, sample.title) {
            TranscriptSample(items: [.activity(sample.value)])
          }
        }),
      .component(
        .transcript, "turn", "Turn Chrome",
        summary: "The worked fold, the working indicator and the plan card.",
        systemImage: "clock.arrow.circlepath", canvas: .column(width: 820),
        keywords: ["worked", "plan", "working"],
        states: [
          CatalogState("worked", "Worked fold") {
            CatalogStack {
              WorkedFold(
                items: TranscriptSamples.tools, isLive: false, duration: 106, decorations: [:])
            }
          },
          CatalogState("live", "Working, live") {
            CatalogStack {
              WorkedFold(
                items: TranscriptSamples.tools, isLive: true, duration: 12, decorations: [:])
              WorkingIndicator(isBlocked: false, startedAt: Date().addingTimeInterval(-12))
            }
          },
          CatalogState("answered", "Settled answer") {
            CatalogStack {
              WorkedFold(
                items: TranscriptSamples.tools, isLive: false, duration: 106, decorations: [:])
              MessageRowView(
                row: Row(
                  id: "answer", role: .assistant, text: "Fixed: the refresh now coalesces.",
                  responseId: "resp_1"),
                decoration: MessageDecoration(timestamp: Date(), workedFor: 106))
            }
          },
          CatalogState("blocked", "Waiting on you") {
            CatalogStack { WorkingIndicator(isBlocked: true) }
          },
          CatalogState("plan", "Plan card") {
            CatalogStack {
              if let todos = PreviewData.shellConversation.section("todos") {
                PlanCard(section: todos)
              }
            }
          },
        ]),
      .component(
        .transcript, "banners", "Banners",
        summary: "Connection errors, failed turns, superseded sessions and the empty transcript.",
        systemImage: "exclamationmark.bubble", canvas: .column(width: 820),
        keywords: ["error", "empty", "failure"],
        states: [
          CatalogState("error", "Connection error") {
            CatalogStack {
              ErrorBanner(
                message: "Lost connection to the server. Reconnecting in 4 seconds.", dismiss: {},
                retry: {})
            }
          },
          CatalogState("failure", "Failed turn") {
            CatalogStack {
              FailureBanner(message: "The provider rejected the request: Invalid API key.") {}
            }
          },
          CatalogState("failure-long", "Failed turn, long message") {
            CatalogStack { FailureBanner(message: CatalogSamples.longText, resume: nil) }
          },
          CatalogState("empty", "Empty transcript") {
            EmptyTranscriptView(state: PreviewData.emptyConversation).frame(height: 360)
          },
        ]),
      .component(
        .transcript, "subagents", "Sub-agent Group",
        summary: "A parent's children: running, blocked (answerable here), finished and failed.",
        systemImage: "arrow.triangle.branch", canvas: .column(width: 820),
        keywords: ["child", "agents"],
        states: [
          CatalogState("group", "Group", note: "The blocked child's request is answerable here.") {
            CatalogStack {
              SubagentGroupView(
                state: PreviewData.subagentConversation, actions: GalleryActions.conversation)
            }
          },
          CatalogState("rows", "Child rows") { SubagentRowSample() },
          CatalogState("parent", "Route back to the parent") {
            CatalogStack { ParentSessionBanner(parentID: PreviewData.sessionID) { _ in } }
          },
        ],
        live: { _ in AnyView(SubagentPlayground()) }),
      .component(
        .transcript, "terminal", "Terminal Pane",
        summary: "Terminal mode's states: starting, offline, harness stopped and resuming.",
        systemImage: "apple.terminal", canvas: .column(width: 720),
        keywords: ["sandbox", "resume"],
        states: [
          terminal("starting", "Starting", .startingUp(stage: "Provisioning sandbox")),
          terminal("offline", "Sandbox offline", .sandboxOffline),
          terminal("stopped", "Harness not running", .harnessNotRunning),
          terminal("resuming", "Resuming", .resuming),
          terminal("ready", "Ready", .ready),
        ]),
      .component(
        .transcript, "transcript", "Transcript",
        summary: "The lazy transcript with folds, decisions and Jump to latest.",
        systemImage: "text.alignleft", canvas: .fixed(width: 820, height: 860),
        keywords: ["conversation", "scroll"],
        states: [
          CatalogState("streaming", "Streaming") {
            TranscriptView(
              state: PreviewData.shellConversation, actions: GalleryActions.conversation)
          },
          CatalogState("approvals", "Inline approvals") {
            TranscriptView(state: TranscriptSamples.approvals, actions: GalleryActions.conversation)
          },
          CatalogState("failed", "Failed") {
            TranscriptView(
              state: PreviewData.failedConversation, actions: GalleryActions.conversation)
          },
          CatalogState("empty", "Empty") {
            TranscriptView(
              state: PreviewData.emptyConversation, actions: GalleryActions.conversation)
          },
          CatalogState("long", "3,000 rows") {
            TranscriptView(
              state: PreviewData.largeConversation(count: 3_000),
              actions: GalleryActions.conversation)
          },
        ]),
    ]
  }

  private static func message(_ id: String, _ title: String, _ row: Row) -> CatalogState {
    CatalogState(id, title) {
      CatalogStack {
        MessageRowView(
          row: row,
          decoration: MessageDecoration(
            timestamp: PreviewData.now, showsActions: row.role == .assistant))
      }
      .environment(\.conversationActions, GalleryActions.conversation)
    }
  }

  private static func terminal(_ id: String, _ title: String, _ status: TerminalStatus)
    -> CatalogState
  {
    CatalogState(id, title) {
      TerminalPane(
        status: status, resume: {}, content: { TerminalPlaceholderView(harness: "codex") }
      )
      .frame(height: 360)
    }
  }
}

extension Row {
  /// The sample assistant reply with markdown, for catalog states.
  fileprivate var assistantSample: Row {
    Row(id: "assistant", role: .assistant, text: PreviewData.assistantMarkdown, agent: "Codex")
  }
}

/// Transcript items picked from the sample conversation.
enum TranscriptSamples {
  static var items: [TranscriptItem] {
    TranscriptView.segments(for: PreviewData.shellConversation).flatMap { segment in
      switch segment {
      case .item(let item): [item]
      case .worked(_, _, let items, _): items
      }
    }
  }

  static var tools: [TranscriptItem] {
    Array(items.filter { if case .tools = $0 { true } else { false } }.prefix(2))
  }

  static var runningTools: [TranscriptItem] {
    [
      .tools(
        id: "running",
        entries: [
          ToolEntry(
            call: PreviewData.tool(
              "run_call", kind: .toolCall, title: "Bash", summary: "cargo test -p omnigent-core",
              details: [], callId: "call_run", status: "in_progress", isStreaming: true),
            result: nil)
        ])
    ]
  }

  static let activities: [CatalogSampleItem<Row>] = [
    CatalogSampleItem(
      "reasoning", "Reasoning",
      PreviewData.activity(
        "r", .reasoning, title: "Reasoning summary",
        summary: "Each caller starts its own refresh; a shared future fixes the race.")
    ),
    CatalogSampleItem(
      "terminal", "Terminal output",
      PreviewData.activity(
        "t", .terminal, title: "zsh",
        summary: "$ cargo test -p omnigent-core\nrunning 214 tests\ntest refresh::expiry ... ok")
    ),
    CatalogSampleItem(
      "error", "Error",
      PreviewData.activity(
        "e", .error, title: "Provider error", summary: "Invalid API key", isFailure: true)
    ),
    CatalogSampleItem(
      "retry", "Retry",
      PreviewData.activity(
        "rt", .retry, title: "Retrying", summary: "Rate limited; retrying in 8 seconds.")
    ),
    CatalogSampleItem(
      "compaction", "Compaction",
      PreviewData.activity(
        "c", .compaction, title: "Context compacted", summary: "Summarized 182 earlier messages.")
    ),
    CatalogSampleItem(
      "sidechat", "Side chat",
      PreviewData.activity(
        "sc", .sidechat, title: "Side chat", summary: "Why does the refresh test flake on CI?")
    ),
    CatalogSampleItem(
      "unknown", "Unknown item",
      PreviewData.activity(
        "u", .unknown, title: "future_item_type", summary: "{\"type\": \"future_item_type\"}")
    ),
  ]

  static var approvals: ConversationViewState {
    var state = PreviewData.shellConversation
    state.header.status = .needsResponse
    state.decisions = PreviewData.approvalRequests
    return state
  }
}

/// Transcript items laid out eagerly in a reading column.
private struct TranscriptSample: View {
  let items: [TranscriptItem]

  var body: some View {
    CatalogStack(spacing: Theme.Spacing.row) {
      ForEach(items) { item in TranscriptItemView(item: item, decorations: [:]) }
    }
    .environment(\.conversationActions, GalleryActions.conversation)
  }
}

private struct DiffSample: View {
  var body: some View {
    CatalogStack {
      if let diff = DiffSummary.find(in: PreviewData.patch) {
        DiffCountsView(added: diff.added, removed: diff.removed)
        DiffView(diff: diff)
      } else {
        Text("The sample patch has no diff.").foregroundStyle(.secondary)
      }
    }
  }
}

private struct SubagentRowSample: View {
  var body: some View {
    CatalogStack(spacing: Theme.Spacing.small) {
      ForEach(SubagentStatus.allCases, id: \.self) { status in
        SubagentChildRow(
          child: SubagentChild(
            id: "child_\(status.rawValue)", title: "Check the \(status.title.lowercased()) path",
            agent: "Codex", goal: "Verify the migration on a copy of the database",
            activity: "Running the migration check",
            error: status == .failed ? "The migration check timed out." : nil, status: status,
            startedAt: PreviewData.now.addingTimeInterval(-150)),
          open: { _ in })
      }
    }
  }
}
