import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  @testable import OmnigentUITestSupport
#endif

/// A project's board: its lanes, cards, drops, keyboard moves, and what clicks on it do.
@Suite("Project board", .serialized)
@MainActor
struct ProjectBoardViewTests {
  final class Calls {
    var log: [String] = []
  }

  private static func actions(_ calls: Calls) -> ProjectBoardActions {
    var actions = ProjectBoardActions { calls.log.append("open \($0)") }
    actions.quickView = { calls.log.append("quick \($0 ?? "none")") }
    actions.setFilter = { calls.log.append("filter \($0)") }
    actions.accepts = { from, to in
      (from == .unread && to == .done) || (from == .done && to == .unread)
    }
    actions.drop = { card, lane in calls.log.append("drop \(card.id) \(lane.rawValue)") }
    actions.setUnread = { card, unread in calls.log.append("unread \(card.id) \(unread)") }
    actions.loadMore = { calls.log.append("more") }
    actions.retry = { calls.log.append("retry") }
    actions.toggleComposer = { calls.log.append("composer") }
    actions.sessions = SessionListActions(
      setArchived: { calls.log.append("archive \($0.id) \($1)") },
      rename: { calls.log.append("rename \($0.id) \($1)") },
      fork: { calls.log.append("fork \($0.id)") })
    return actions
  }

  @Test(
    "The lanes run Draft, Needs attention, Working, Unread, Done; a phone opens on the first with cards"
  )
  func laneOrder() {
    #expect(
      ProjectBoardLane.allCases.map(\.title) == [
        "Draft", "Needs attention", "Working", "Unread", "Done",
      ])
    var state = PreviewData.emptyBoardState
    #expect(state.openingLane == .draft)
    state.columns[3].cards = PreviewData.boardState.columns[3].cards
    #expect(state.openingLane == .unread)
    #expect(state.emptyLabel == "No sessions")
    state.filter = " login "
    #expect(state.emptyLabel == "No matching sessions")
    #expect(PreviewData.boardState.card("board_working")?.nestedCount == 2)
  }

  @Test("Lanes share the width between the minimum and the web's maximum")
  func laneWidths() {
    #expect(ProjectBoardLayout.laneWidth(for: 600) == 220)
    #expect(ProjectBoardLayout.laneWidth(for: 4_000) == 456)
    let width = ProjectBoardLayout.laneWidth(for: 1_400)
    #expect(width > 220 && width < 456)
  }

  @Test("A drag carries its card, and only Unread and Done take each other's cards")
  func drops() {
    #expect(ProjectBoardDrag.cardID(ProjectBoardDrag.payload("s1")) == "s1")
    #expect(ProjectBoardDrag.cardID("https://example.test") == nil)
    let calls = Calls()
    var dragging: String? = "board_unread"
    var targeted: ProjectBoardLane? = .done
    let drop = { (lane: ProjectBoardLane) in
      ProjectBoardLaneDrop(
        lane: lane, state: PreviewData.boardState, actions: Self.actions(calls),
        dragging: Binding(get: { dragging }, set: { dragging = $0 }),
        targeted: Binding(get: { targeted }, set: { targeted = $0 }))
    }
    #expect(drop(.done).card("board_unread") != nil)
    #expect(drop(.working).card("board_unread") == nil, "Working follows live status")
    #expect(drop(.unread).card("board_unread") == nil, "its own lane")
    #expect(drop(.unread).card("board_done") != nil)
    #expect(drop(.done).card("missing") == nil)

    #expect(drop(.done).drop("board_unread"))
    #expect(calls.log == ["drop board_unread done"])
    #expect(dragging == nil && targeted == nil, "a drop ends the drag")
    #expect(!drop(.draft).drop("board_done"))
    #expect(calls.log.count == 1)
  }

  @Test("Arrow keys move along a lane and across to the nearest card")
  func focusMoves() {
    let columns = PreviewData.boardState.columns
    typealias Focus = ProjectBoardFocus
    #expect(Focus.next(from: nil, .below, in: columns) == "board_draft")
    #expect(Focus.next(from: "board_approval", .below, in: columns) == "board_failed")
    #expect(Focus.next(from: "board_failed", .below, in: columns) == "board_failed")
    #expect(Focus.next(from: "board_failed", .above, in: columns) == "board_approval")
    #expect(Focus.next(from: "board_failed", .right, in: columns) == "board_working")
    #expect(Focus.next(from: "board_unread", .right, in: columns) == "board_done")
    #expect(Focus.next(from: "board_done", .right, in: columns) == "board_done")
    var sparse = columns
    sparse[2].cards = []
    #expect(Focus.next(from: "board_approval", .right, in: sparse) == "board_unread")
  }

  #if os(macOS)
    private func screen(
      _ state: ProjectBoardViewState = PreviewData.boardState, calls: Calls,
      width: CGFloat = 1_440, height: CGFloat = 820
    ) -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      var projectActions = SidebarActions(sessions: SessionListActions())
      projectActions.openProjectSettings = { calls.log.append("settings \($0.id)") }
      projectActions.renameProject = { _, name, _ in calls.log.append("rename \(name)") }
      projectActions.deleteProject = { calls.log.append("delete \($0.id)") }
      let view = ProjectBoardView(
        state: state, actions: Self.actions(calls), projectActions: projectActions,
        composer: { Text("Floating composer").padding().background(.background) },
        quickView: { Text("Chat of \($0)") })
      return OffscreenWindow(view, width: width, height: height, appearance: .aqua)
    }

    @Test("Each lane shows its title, count and cards; family cards count their nested agents")
    func lanesShowCards() throws {
      let shown = screen(calls: Calls())
      defer { shown.close() }
      for title in ["Draft", "Needs attention", "Working", "Unread", "Done"] {
        #expect(try shown.shows(title), "\(title) lane")
      }
      #expect(try shown.shows("Fix flaky SSE reconnect test"))
      #expect(try shown.shows("Port session query to Rust"))
      // The details line is one run of text whose parts keep their words together.
      #expect(try shown.shownText().contains { $0.contains("2\u{00A0}nested") })
      #expect(try shown.shows("Docs site"))
      #expect(try shown.shows("New Session"))
    }

    @Test("An empty board says so in every lane, and a filter says nothing matches")
    func emptyBoard() throws {
      let shown = screen(PreviewData.emptyBoardState, calls: Calls())
      defer { shown.close() }
      #expect(try shown.shownText().filter { $0 == "No sessions" }.count == 5)
      var filtered = PreviewData.emptyBoardState
      filtered.filter = "login"
      let none = screen(filtered, calls: Calls())
      defer { none.close() }
      #expect(try none.shows("No matching sessions"))
    }

    @Test("A card opens its session; its quick view button opens it beside the lanes")
    func cardClicks() throws {
      let calls = Calls()
      let shown = screen(calls: calls)
      defer { shown.close() }
      try shown.clickElement("project-board-card-board_unread")
      #expect(calls.log == ["open board_unread"])
      calls.log = []
      let card = try shown.withAccessibilityTree {
        try shown.accessibilityFrame("project-board-card-board_unread")
      }
      try shown.hover(CGPoint(x: card.midX, y: card.midY))
      try shown.clickElement("project-board-peek-board_unread")
      #expect(calls.log == ["quick board_unread"])
    }

    @Test("A card's menu has the row's board actions and marks the whole card read")
    func cardMenu() throws {
      let calls = Calls()
      let shown = screen(calls: calls)
      defer { shown.close() }
      let card = try shown.withAccessibilityTree {
        try shown.accessibilityFrame("project-board-card-board_unread")
      }
      let menu = try #require(try shown.contextMenu(at: CGPoint(x: card.midX, y: card.midY)))
      let titles = menu.items.map(\.title)
      #expect(titles.contains("Mark as read"))
      #expect(titles.contains("Fork"))
      #expect(!titles.contains("Pin"), "pins don't change the board")
      #expect(!titles.contains("Share"))
      try shown.choose("Mark as read", in: menu)
      #expect(calls.log == ["unread board_unread false"])
    }

    @Test("New Session floats the composer; the header offers settings and the filter")
    func header() throws {
      let calls = Calls()
      let shown = screen(calls: calls)
      defer { shown.close() }
      try shown.clickElement("project-board-new-session")
      try shown.clickElement("project-board-settings")
      #expect(calls.log == ["composer", "settings proj_docs"])
      var open = PreviewData.boardState
      open.isComposerShown = true
      let floating = screen(open, calls: Calls())
      defer { floating.close() }
      #expect(try floating.shows("Floating composer"))
    }

    @Test("Quick view shows the session beside the lanes, opens it in full and closes")
    func quickViewPanel() throws {
      let calls = Calls()
      var state = PreviewData.boardState
      state.quickViewID = "board_unread"
      let shown = screen(state, calls: calls)
      defer { shown.close() }
      #expect(try shown.shows("Chat of board_unread"))
      try shown.clickElement("project-board-quick-view-open")
      try shown.clickElement("project-board-quick-view-close")
      #expect(calls.log == ["open board_unread", "quick none"])
    }

    @Test("A board that failed to load offers Try Again, and More loads the next page")
    func loadingStates() throws {
      let calls = Calls()
      var failed = PreviewData.boardState
      failed.phase = .failed(message: "The server is unreachable.")
      let shown = screen(failed, calls: calls)
      defer { shown.close() }
      #expect(try shown.shows("Couldn\u{2019}t Load Sessions"))
      try shown.clickElement("project-board-retry")
      var more = PreviewData.boardState
      more.hasMore = true
      let paged = screen(more, calls: calls)
      defer { paged.close() }
      try paged.clickElement("project-board-load-more")
      #expect(calls.log == ["retry", "more"])
    }
  #endif
}
