import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar selection and drag and drop")
struct SidebarInteractionTests {
  private let order = ["a", "b", "c", "d", "e"]

  @Test("Clicks toggle rows; Shift-click checks the range from the last toggled row")
  func bulkSelection() {
    var selection = SidebarBulkSelection()
    selection.begin()
    #expect(selection.isActive && selection.ids.isEmpty)
    selection.toggle("b", extending: false, order: order)
    selection.toggle("d", extending: true, order: order)
    #expect(selection.ids == ["b", "c", "d"])
    // Upward ranges work too, and a range never unchecks.
    selection.toggle("a", extending: true, order: order)
    #expect(selection.ids == ["a", "b", "c", "d"])
    selection.toggle("c", extending: false, order: order)
    #expect(selection.ids == ["a", "b", "d"])
    #expect(selection.anchor == "c")
    // Without an anchor on screen, Shift-click toggles the row alone.
    selection.toggle("z", extending: true, order: order)
    #expect(selection.ids.contains("z"))
    selection.clear()
    #expect(selection.isActive && selection.ids.isEmpty && selection.anchor == nil)
    selection.end()
    #expect(!selection.isActive)
  }

  @Test("Drops resolve as the web's resolveSidebarDrop")
  func dropResolution() {
    let alpha = SessionProject(id: "p1", name: "Alpha", sessionIds: ["filed"], projectID: "p1")
    let beta = SessionProject(id: "p2", name: "Beta", sessionIds: [], projectID: "p2")
    let loose = SessionSummary(id: "loose", title: "Loose")
    let pinned = SessionSummary(id: "pin", title: "Pin", isPinned: true)
    let filed = SessionSummary(id: "filed", title: "Filed")
    func resolve(
      _ session: SessionSummary, in project: SessionProject? = nil, shared: Bool = false,
      on target: SidebarDropTarget
    ) -> SidebarDropAction {
      .resolve(session: session, project: project, isShared: shared, target: target)
    }
    #expect(resolve(loose, on: .project(alpha)) == .move(to: alpha, unpin: false))
    #expect(resolve(filed, in: alpha, on: .project(alpha)) == .none)
    #expect(resolve(filed, in: alpha, on: .project(beta)) == .move(to: beta, unpin: false))
    #expect(resolve(pinned, on: .project(alpha)) == .move(to: alpha, unpin: true))
    #expect(resolve(loose, shared: true, on: .project(alpha)) == .none)
    #expect(resolve(loose, on: .pinned) == .pin(slotOf: nil))
    #expect(resolve(pinned, on: .pinned) == .none)
    #expect(resolve(loose, on: .pinSlot("pin")) == .pin(slotOf: "pin"))
    #expect(resolve(pinned, on: .pinSlot("pin")) == .none)
    #expect(resolve(filed, in: alpha, on: .sessions) == .ungroup(unpin: false))
    #expect(resolve(pinned, on: .sessions) == .unpin)
    #expect(resolve(loose, on: .sessions) == .none)
  }

  @Test("Drag payloads round-trip and a project moves into the target's slot")
  func payloadsAndReorder() {
    #expect(SidebarDragItem(payload: SidebarDragItem.session("s1").payload) == .session("s1"))
    #expect(SidebarDragItem(payload: SidebarDragItem.project("p1").payload) == .project("p1"))
    #expect(SidebarDragItem(payload: "plain text") == nil)
    let projects = ["a", "b", "c"].map { SessionProject(id: $0, name: $0, sessionIds: []) }
    #expect(
      SessionProject.reordered(projects, moving: "c", onto: "a").map(\.id) == ["c", "a", "b"])
    #expect(
      SessionProject.reordered(projects, moving: "a", onto: "c").map(\.id) == ["b", "c", "a"])
    #expect(SessionProject.reordered(projects, moving: "a", onto: "a").isEmpty)
    #expect(SessionProject.reordered(projects, moving: "x", onto: "a").isEmpty)
  }

  @Test("Move up, down, to top and to bottom, as the web's moveProject")
  func projectMoves() {
    let projects = ["a", "b", "c"].map { SessionProject(id: $0, name: $0, sessionIds: []) }
    func moved(_ id: String, _ move: ProjectMove) -> [String] {
      SessionProject.moved(projects, id: id, move).map(\.id)
    }
    #expect(moved("b", .upOne) == ["b", "a", "c"])
    #expect(moved("b", .downOne) == ["a", "c", "b"])
    #expect(moved("c", .top) == ["c", "a", "b"])
    #expect(moved("a", .bottom) == ["b", "c", "a"])
    // Nothing to do at either end, or for a project that is not there.
    #expect(moved("a", .upOne).isEmpty && moved("a", .top).isEmpty)
    #expect(moved("c", .downOne).isEmpty && moved("c", .bottom).isEmpty)
    #expect(moved("x", .top).isEmpty)
  }

  @Test("The row tooltip adds Created by, Repo and Branch below the summary")
  func rowTooltip() {
    let session = SessionSummary(id: "s", title: "Fix the build")
    let now = session.updatedDate.addingTimeInterval(120)
    #expect(
      SessionRowTooltip.text(session, info: SessionRowInfo(), now: now)
        == "Fix the build\nUpdated 2m ago")
    var info = SessionRowInfo(repo: "omnigent", branch: "main")
    info.createdBy = "You"
    #expect(
      SessionRowTooltip.text(session, info: info, now: now)
        == "Fix the build\nUpdated 2m ago\n\nCreated by: You\nRepo: omnigent\nBranch: main")
  }

  @Test("Stop session explains that a host session's runner stops too")
  func stopMessage() {
    let session = SessionSummary(id: "s", title: "Deploy")
    #expect(
      StopSessionConfirmation.message(session, runsOnHost: false)
        == "This terminates the running session for \u{201C}Deploy\u{201D}. Conversation histories are kept."
    )
    #expect(
      StopSessionConfirmation.message(session, runsOnHost: true).contains(
        "and stops its runner, including side chats running on it."))
  }

  @Test("Command-[ and ] wrap at the ends; off the list they enter at the top or bottom")
  func sessionStep() {
    #expect(SidebarNavigationOrder.step(from: "e", by: 1, in: order) == "a")
    #expect(SidebarNavigationOrder.step(from: "a", by: -1, in: order) == "e")
    #expect(SidebarNavigationOrder.step(from: "b", by: 1, in: order) == "c")
    #expect(SidebarNavigationOrder.step(from: nil, by: 1, in: order) == "a")
    #expect(SidebarNavigationOrder.step(from: "gone", by: -1, in: order) == "e")
    #expect(SidebarNavigationOrder.step(from: "a", by: 1, in: ["a"]) == nil)
    #expect(SidebarNavigationOrder.step(from: "a", by: 1, in: []) == nil)
  }

  @Test("Navigation follows the rows on screen: collapsed sections and folders drop out")
  func navigationOrder() {
    let state = PreviewData.sidebar
    let all = SidebarNavigationOrder.sessionIDs(
      state, collapsed: [], expandedProjects: ["proj_gitspoke"])
    #expect(all.first == "sess_p1")
    #expect(all.contains("sess_a2") && !all.contains("sess_w1"))
    let collapsed = SidebarNavigationOrder.sessionIDs(
      state, collapsed: ["Pinned", "Shared"], expandedProjects: [])
    #expect(!collapsed.contains("sess_p1") && !collapsed.contains("sess_a4"))
    #expect(!collapsed.contains("sess_a2"))
  }

  @Test("Rows hold their places under the pointer; pins keep the core's order; new rows go first")
  func heldOrder() {
    let sessions = ["p", "a", "b", "c"].map {
      SessionSummary(id: $0, title: $0, isPinned: $0 == "p")
    }
    let order = ["p": 0, "a": 1, "b": 2, "c": 3]
    // "c" updated and the core moved it up; "n" is new.
    let live = [
      sessions[0], SessionSummary(id: "n", title: "n"), sessions[3], sessions[1], sessions[2],
    ]
    #expect(SidebarBehavior.holding(live, order: order).map(\.id) == ["p", "n", "a", "b", "c"])
    #expect(SidebarBehavior.addsPin(["p"], ["p", "a"]))
    #expect(!SidebarBehavior.addsPin(["p", "a"], ["a"]))
  }

  @Test("A collapsed header shows its rows' strongest state, as the web's projectMarkerState")
  func hiddenMarker() {
    let list = PreviewData.sessionList
    let rowInfo = PreviewData.rowInfo
    #expect(
      SidebarMarker.strongest(list.sessions, list: list, rowInfo: rowInfo)
        == .needsYou(requests: 2))
    let quiet = list.sessions.filter { $0.attention != .needsYou }
    #expect(SidebarMarker.strongest(quiet, list: list, rowInfo: rowInfo) == .working)
    let idle = list.sessions.filter { $0.id == "sess_m1" || $0.id == "sess_y1" }
    #expect(SidebarMarker.strongest(idle, list: list, rowInfo: rowInfo) == .disconnected)
    #expect(SidebarMarker.strongest(idle.suffix(0), list: list, rowInfo: rowInfo) == nil)
  }
}

@Suite("Sidebar inline rename")
struct SidebarInlineEditTests {
  private func session(_ title: String) -> SessionSummary {
    var session = PreviewData.sessions[0]
    session.title = title
    return session
  }

  @Test func savesATrimmedNewTitleOnce() {
    var edit = SidebarInlineEdit()
    edit.begin(session("Old"))
    #expect(edit.text == "Old")
    edit.text = "  New  "
    #expect(edit.finish()?.title == "New")
    #expect(edit.session == nil)
    #expect(edit.finish() == nil)
  }

  @Test func savesNothingForEmptyUnchangedOrOverlongTitles() {
    for text in ["   ", "Old", String(repeating: "x", count: SessionDialogs.maxTitleLength + 1)] {
      var edit = SidebarInlineEdit()
      edit.begin(session("Old"))
      edit.text = text
      #expect(edit.finish() == nil)
      #expect(edit.session == nil)
    }
  }
}
