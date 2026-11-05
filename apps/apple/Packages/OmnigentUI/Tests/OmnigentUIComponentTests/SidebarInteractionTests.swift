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
}
