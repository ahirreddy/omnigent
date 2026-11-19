import Foundation
import SwiftUI

// Sample data for a project's board: a card in every lane, a family card, and the empty board.
extension PreviewData {
  static let boardProject = SessionProject(
    id: "proj_docs", name: "Docs site", sessionIds: [], projectID: "proj_docs")

  private static func boardCard(
    _ id: String, _ title: String, lane: ProjectBoardLane,
    attention: SessionAttentionState = .idle, hoursAgo: Double, preview: String? = nil,
    info: SessionRowInfo = SessionRowInfo(), members: [String] = [], isUnread: Bool = false,
    requests: Int = 0, failure: String? = nil
  ) -> ProjectBoardCard {
    let session = summary(
      id, title, preview: "", hoursAgo: hoursAgo, failure: failure, attention: attention)
    return ProjectBoardCard(
      session: session, info: info, memberIDs: members, lane: lane, isUnread: isUnread,
      requests: requests, preview: preview)
  }

  /// A board with work in every lane.
  static var boardState: ProjectBoardViewState {
    let columns = [
      ProjectBoardColumn(
        lane: .draft,
        cards: [
          boardCard(
            "board_draft", "Write the migration guide", lane: .draft, hoursAgo: 3,
            preview: "Outlined the three breaking changes. The examples wait on the final names.",
            info: SessionRowInfo(harness: "claude-native", repo: "docs", hasDraft: true))
        ]),
      ProjectBoardColumn(
        lane: .needsAttention,
        cards: [
          boardCard(
            "board_approval", "Fix flaky SSE reconnect test", lane: .needsAttention,
            attention: .needsYou, hoursAgo: 0.4,
            preview: "The retry timer races the reconnect. I need approval to run the suite.",
            info: SessionRowInfo(
              harness: "claude-native", environment: "Managed sandbox", repo: "omnigent",
              branch: "sse-retry"),
            requests: 2),
          boardCard(
            "board_failed", "Nightly dependency bump", lane: .needsAttention,
            attention: .failed, hoursAgo: 2,
            preview: "Bumped 14 crates. The provider rejected the request.",
            info: SessionRowInfo(harness: "codex-native", environment: "CI runner"),
            failure: "Invalid API key"),
        ]),
      ProjectBoardColumn(
        lane: .working,
        cards: [
          boardCard(
            "board_working", "Refactor token refresh and add tests", lane: .working,
            attention: .working, hoursAgo: 0.05,
            info: SessionRowInfo(
              harness: "codex-native", environment: "This Mac", repo: "omnigent",
              branch: "auth-refresh"),
            members: ["board_working", "board_nested_a", "board_nested_b"])
        ]),
      ProjectBoardColumn(
        lane: .unread,
        cards: [
          boardCard(
            "board_unread", "Port session query to Rust", lane: .unread, attention: .unread,
            hoursAgo: 1, preview: "Done. All 24 tests pass and the Swift copy is gone.",
            info: SessionRowInfo(harness: "codex-native", repo: "omnigent"), isUnread: true)
        ]),
      ProjectBoardColumn(
        lane: .done,
        cards: [
          boardCard(
            "board_done", "Add dark mode screenshots", lane: .done, hoursAgo: 26,
            preview: "Captured light and dark for every page. They are in the docs folder.",
            info: SessionRowInfo(harness: "pi", repo: "docs")),
          boardCard(
            "board_spike", "Spike: WASM build of the core", lane: .done, hoursAgo: 24 * 6,
            preview: "The wasm32 check passes.",
            info: SessionRowInfo(harness: "antigravity")),
        ]),
    ]
    var state = ProjectBoardViewState(project: boardProject, columns: columns)
    state.details = [.updated, .environment, .repo, .branch]
    state.projects = [boardProject] + projects
    state.now = now
    return state
  }

  /// A project with no sessions yet.
  static var emptyBoardState: ProjectBoardViewState {
    var state = ProjectBoardViewState(project: boardProject)
    state.projects = [boardProject]
    state.now = now
    return state
  }

  /// The sample board, its composer and quick view drawn from sample data.
  /// - Parameters:
  ///   - state: The board.
  ///   - open: Opens a card's session.
  /// - Returns: The page.
  static func projectBoard(
    _ state: ProjectBoardViewState = boardState, open: @escaping @MainActor (String) -> Void
  ) -> some View {
    var actions = ProjectBoardActions(open: open)
    actions.quickView = { _ in }
    actions.setFilter = { _ in }
    actions.accepts = { from, to in
      (from == .unread && to == .done) || (from == .done && to == .unread)
    }
    actions.drop = { _, _ in }
    actions.setUnread = { _, _ in }
    actions.toggleComposer = {}
    actions.sessions = SessionListActions(
      setArchived: { _, _ in }, rename: { _, _ in }, setUnread: { _, _ in },
      fork: { _ in }, moveToProject: { _, _ in }, delete: { _ in })
    var projectActions = SidebarActions(sessions: actions.sessions)
    projectActions.openProjectSettings = { _ in }
    projectActions.renameProject = { _, _, _ in }
    projectActions.deleteProject = { _ in }
    return ProjectBoardView(
      state: state, actions: actions, projectActions: projectActions,
      composer: { PreviewBoardComposer() },
      quickView: { _ in
        ContentUnavailableView(
          "Session", systemImage: TabKind.chat.systemImage,
          description: Text("The session's chat shows here."))
      })
  }
}

/// The new-session composer as the board floats it, from sample data.
private struct PreviewBoardComposer: View {
  @State private var draft = ""

  var body: some View {
    NewSessionPage(
      draft: $draft, composer: PreviewData.startComposer, actions: ComposerActions(send: {}),
      isFloating: true)
  }
}
