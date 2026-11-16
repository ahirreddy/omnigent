import Testing

@testable import OmnigentUIComponents
@testable import OmnigentUITestSupport

/// The open session's row arrives by itself, first in Pinned, and the earlier pins arrive above it
/// afterwards: what a window does when its session is read before the list is.
private enum OpenPinArrival {
  static let open = SessionSummary(id: "open", title: "Open pin", updatedAt: 90, isPinned: true)
  static let earlier = (1...8).map { number in
    SessionSummary(id: "pin-\(number)", title: "Earlier pin \(number)", isPinned: true)
  }
  static let loose = [
    SessionSummary(id: "loose-1", title: "Loose one", updatedAt: 50),
    SessionSummary(id: "loose-2", title: "Loose two", updatedAt: 40),
    SessionSummary(id: "filed", title: "Filed", updatedAt: 30),
  ]
  static let folder = SessionProject(id: "work", name: "Work", sessionIds: ["filed"])

  static func state(_ sessions: [SessionSummary], folders: [SessionProject] = [])
    -> SidebarViewState
  {
    var state = SidebarViewState(list: SessionListViewState(sessions: sessions))
    state.projects = folders
    return state
  }

  static var alone: SidebarViewState { state([open]) }
  static var loaded: SidebarViewState { state(earlier + [open] + loose, folders: [folder]) }
}

@Suite("Sidebar list selection")
struct SidebarListSelectionTests {
  /// How many rows draw each session, over the sections and the folders.
  private func rowCounts(_ state: SidebarViewState) -> [String: Int] {
    let sections = SidebarSections.sections(state)
    var counts: [String: Int] = [:]
    for section in sections where !section.isProjects {
      for session in section.sessions { counts[session.id, default: 0] += 1 }
    }
    for id in state.projects.flatMap(\.sessionIds) { counts[id, default: 0] += 1 }
    return counts
  }

  @Test("Every session has one row while rows arrive, hold still, re-sort, turn unread and pin")
  func oneRowPerSession() {
    var state = OpenPinArrival.alone
    #expect(rowCounts(state) == ["open": 1])
    state = OpenPinArrival.loaded
    let everySessionOnce = Dictionary(
      uniqueKeysWithValues: state.list.sessions.map { ($0.id, 1) })
    #expect(rowCounts(state) == everySessionOnce)

    // The pointer is over the list while a running session passes another and one turns unread.
    var held: [String: Int] = [:]
    for (index, session) in state.list.sessions.enumerated() { held[session.id] = index }
    let moved = state.list.sessions.remove(at: 10)
    state.list.sessions.insert(moved, at: 9)
    state.list.unreadIds = ["open"]
    var holding = state
    holding.list.sessions = SidebarBehavior.holding(state.list.sessions, order: held)
    #expect(rowCounts(holding) == everySessionOnce)
    #expect(holding.list.sessions.map(\.id) == OpenPinArrival.loaded.list.sessions.map(\.id))

    state.list.sessions[9].isPinned = true
    #expect(rowCounts(state) == everySessionOnce)
    let pinned = SidebarSections.sections(state).first(where: \.isPinned)?.sessions.map(\.id)
    #expect(pinned == OpenPinArrival.earlier.map(\.id) + ["open", "loose-2"])
  }

  @Test("A session's group is its section or its folder; a page and a hidden session have none")
  func groups() {
    let state = OpenPinArrival.loaded
    let sections = SidebarSections.sections(state)
    let groups = SidebarListSelection.groups(sections, projects: state.projects)
    #expect(groups == ["section:Pinned", "section:Sessions", "project:work"])
    func group(_ id: String) -> String? {
      SidebarListSelection.group(of: id, sections: sections, projects: state.projects)
    }
    #expect(group("open") == "section:Pinned")
    #expect(group("loose-1") == "section:Sessions")
    #expect(group("filed") == "project:work")
    #expect(group("filtered-out") == nil)

    // Other groupings have no folders, so a filed session is a row of its section.
    var byStatus = state
    byStatus.display.groupBy = .status
    let statusSections = SidebarSections.sections(byStatus)
    #expect(
      SidebarListSelection.group(of: "filed", sections: statusSections, projects: state.projects)
        == "section:Done")
    #expect(
      !SidebarListSelection.groups(statusSections, projects: state.projects)
        .contains("project:work"))
  }

  @Test("The list is told a session once its group is drawn; pages and rowless sessions pass")
  func listed() {
    let open = SidebarDestination.session("open")
    let drawn: Set<String> = ["section:Sessions"]
    #expect(SidebarListSelection.listed(open, group: "section:Pinned", drawn: drawn) == nil)
    #expect(SidebarListSelection.listed(open, group: "section:Sessions", drawn: drawn) == open)
    #expect(SidebarListSelection.listed(open, group: nil, drawn: drawn) == open)
    #expect(SidebarListSelection.listed(.inbox, group: nil, drawn: []) == .inbox)
    #expect(SidebarListSelection.listed(nil, group: nil, drawn: drawn) == nil)
  }

  @Test("The open session arriving with Pinned is told one update late, and not again after")
  @MainActor
  func openPinArrivesWithItsSection() {
    let open = SidebarDestination.session("open")
    let drawn = SidebarDrawnGroups()
    func shown(_ state: SidebarViewState, _ selection: SidebarDestination?) -> SidebarShownGroups {
      drawn.shown(
        SidebarSections.sections(state), projects: state.projects, selection: selection)
    }
    // The update that draws Pinned for the first time, with the open session its only row.
    var groups = shown(OpenPinArrival.alone, open)
    #expect(groups.selected == "section:Pinned")
    #expect(drawn.listed(open, group: groups.selected) == nil && drawn.isHoldingBack)
    drawn.settle(groups.all)
    #expect(drawn.listed(open, group: groups.selected) == open && !drawn.isHoldingBack)

    // The earlier pins arrive above it: Pinned is drawn already, so nothing waits.
    groups = shown(OpenPinArrival.loaded, open)
    #expect(drawn.listed(open, group: groups.selected) == open)
    drawn.settle(groups.all)
    let loose = SidebarDestination.session("loose-1")
    #expect(drawn.listed(loose, group: shown(OpenPinArrival.loaded, loose).selected) == loose)

    // A filter that leaves no pin takes Pinned away; it comes back as a new group.
    groups = shown(OpenPinArrival.state(OpenPinArrival.loose), open)
    #expect(groups.selected == nil && drawn.listed(open, group: nil) == open)
    drawn.settle(groups.all)
    groups = shown(OpenPinArrival.loaded, open)
    #expect(drawn.listed(open, group: groups.selected) == nil && drawn.isHoldingBack)
  }
}

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  @Suite("Sidebar rows drawn once", .serialized)
  @MainActor
  struct SidebarRowsDrawnOnceTests {
    /// Pairs of the list's row views that share a slot: a row the outline drew twice.
    private func rowsSharingASlot(_ screen: OffscreenWindow<SidebarHarness>) throws -> Int {
      let list = try #require(screen.list)
      let frames = screen.allViews
        .filter { $0 is NSTableRowView && !$0.isHidden }
        .map { $0.convert($0.bounds, to: list).insetBy(dx: 0, dy: 1) }
      var pairs = 0
      for (index, frame) in frames.enumerated() {
        pairs += frames[(index + 1)...].filter { frame.intersects($0) }.count
      }
      return pairs
    }

    @Test("The open session alone in Pinned, then the pins above it: each row is drawn once")
    func openPinArrivesBeforeTheList() throws {
      let spy = SidebarSpy(OpenPinArrival.state([]))
      spy.selection = .session("open")
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 900)
      defer { screen.close() }
      spy.state = OpenPinArrival.alone
      #expect(
        MainLoop.settle(until: { screen.list?.selectedRow == SidebarFixture.pinnedRow }),
        "told once Pinned is drawn")
      let list = try #require(screen.list)

      spy.state = OpenPinArrival.loaded
      screen.settle(0.3)
      let shown = try screen.shownText()
      for session in OpenPinArrival.loaded.list.sessions where session.id != "filed" {
        #expect(shown.filter { $0 == session.title }.count == 1, "\(session.title): \(shown)")
      }
      #expect(try rowsSharingASlot(screen) == 0, "no row view is left where the open one was")
      let openRow = SidebarFixture.pinnedRow + OpenPinArrival.earlier.count
      #expect(list.selectedRow == openRow, "the selection follows the open session's row")
      #expect(spy.selection == .session("open"), "the list never cleared the host's selection")

      // Another session opens: only its row is selected, and nothing stays at the top of Pinned.
      spy.selection = .session("pin-3")
      #expect(MainLoop.settle(until: { list.selectedRow == SidebarFixture.pinnedRow + 2 }))
      #expect(try rowsSharingASlot(screen) == 0)
    }
  }
#endif
