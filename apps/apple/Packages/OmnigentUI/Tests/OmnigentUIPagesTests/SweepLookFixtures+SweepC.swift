import Foundation
import SwiftUI

@testable import OmnigentUIComponents

/// Generic data for the third parity sweep's screens: Switch Host into a sandbox, the execution
/// logs' live stream, the session overview, agent cost tags and the Canvas beside a session.
@MainActor
extension SweepLookFixtures {
  /// Switch Host with only a new sandbox on offer, so its repository fields show.
  static var switchHostSandbox: some View {
    let actions = HostMoveActions(
      loadHosts: {
        .success([
          HostMoveTarget(id: "old", name: "Old Mac", isOnline: true),
          HostMoveTarget.sandbox("modal", name: "Modal Sandbox"),
        ])
      },
      home: { _ in nil },
      browse: { _, _ in .failure(FolderBrowseError(message: "No folders")) },
      submit: { _ in .moved },
      sandboxProblem: { _, branch in
        branch.isEmpty
          ? nil : HostMoveRepoProblem(isBranch: false, message: "Add the repository.")
      })
    return HostMoveSheet(kind: .switchHost(currentHostID: "old"), actions: actions) {}
  }

  /// The execution logs' SSE view with a few events.
  static var executionStream: some View {
    let events = [
      #"{"type":"response.created","response":{"id":"resp_1"}}"#,
      #"{"type":"response.output_text.delta","delta":"Reading the upload retry"}"#,
      #"{"type":"session.status","status":"running"}"#,
    ].enumerated().map { index, compact in
      ExecutionStreamEvent(
        index: UInt64(index), receivedAt: now.addingTimeInterval(Double(index) * 0.25),
        compact: compact, pretty: compact)
    }
    return ExecutionStreamLogView(
      sessionID: "conv_a",
      read: { _, after in
        after == nil ? events : []
      })
  }

  /// The session overview with two models and two sub-agents.
  static var sessionOverview: some View {
    var state = PreviewData.conversation
    state.sections = [
      EventSection(
        id: "usage", title: "Usage", summary: "",
        details: [
          DetailSection(id: "overview_cost", title: "Session cost", text: "$1.27"),
          DetailSection(
            id: "overview_models", title: "Cost by model",
            text: "large-model\t$1.19\nsmall-model\t$0.08"),
          DetailSection(id: "overview_tokens", title: "Tokens", text: "184200"),
        ]),
      EventSection(
        id: "child-a", title: "Explore the upload code", summary: "Done", sessionId: "a"),
      EventSection(
        id: "child-b", title: "Write the retry test", summary: "Working", sessionId: "b"),
    ]
    let costs = AgentCostSource { .success(["a": "$0.31", "b": "~$0.12"]) }
    return SessionOverviewView(state: state, costs: costs) {}
  }

  /// The Agents tab with each agent's cost.
  static var agentCosts: some View {
    var main = AgentTreeNode(id: "root", name: "Main chat", activity: .working, childCount: 2)
    main.costLabel = "$1.27"
    var explore = AgentTreeNode(
      id: "a", parentID: "root", depth: 1, name: "Explore the upload code", role: .explore,
      activity: .done, statusLabel: "Done", isSettled: true, preview: "Found the retry loop")
    explore.costLabel = "$0.31"
    var test = AgentTreeNode(
      id: "b", parentID: "root", depth: 1, name: "Write the retry test", role: .test,
      activity: .working, statusLabel: "Working", routedModel: "small-model")
    test.costLabel = "~$0.12"
    return AgentTreePanel(
      state: AgentTreeState(nodes: [main, explore, test], currentID: "root"),
      actions: AgentTreeActions(open: { _ in }))
  }

  /// The import review after onboarding hosts on this Mac.
  static var importReview: some View {
    ImportReviewView(
      phase: .loaded(
        hostName: "Work Mac",
        harnesses: [
          ImportReviewHarnessState(
            id: "claude-native", label: "Claude Code", credential: "Signed in",
            mcpServers: ["docs", "tracker"], skills: ["/review", "/release-notes"],
            plugins: ["kit"]),
          ImportReviewHarnessState(
            id: "codex-native", label: "Codex", credential: nil, mcpServers: [],
            skills: ["$plan"], plugins: []),
        ]),
      seeMore: {}, confirm: {})
  }

  /// The Canvas with a session open beside the board and a card's PR.
  static var canvasQuickView: some View {
    var first = CanvasCard(
      id: "a", title: "Retry uploads on timeout", state: .running, workspace: "/repo/app",
      branch: "feature/retry", left: 0, top: 0)
    first.pullRequest = URL(string: "https://example.com/acme/app/pull/42").map {
      CanvasPullRequest(
        text: "#42 Retry uploads on timeout", url: $0, tooltip: "Retry uploads on timeout (open)",
        accessibilityLabel: "Open pull request #42")
    }
    var second = CanvasCard(
      id: "b", title: "Tidy the README", state: .needsYou, workspace: "/repo/docs", left: 320,
      top: 0)
    second.requests = 2
    var state = CanvasViewState(
      boards: [CanvasBoard(id: "main", name: "Main"), CanvasBoard(id: "p", name: "Uploads")],
      activeBoard: "main", cards: [first, second])
    state.quickViewID = "a"
    var actions = CanvasActions(open: { _ in })
    actions.quickView = { _ in }
    actions.newSession = {}
    actions.resetLayout = {}
    return CanvasView(
      state: state, actions: actions,
      quickView: { _ in
        AnyView(
          Text("The session's chat").foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
      })
  }
}
