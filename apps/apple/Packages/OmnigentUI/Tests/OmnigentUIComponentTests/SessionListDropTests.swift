#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Session list: what a drop does")
  @MainActor
  struct SessionListDropTests {
    private let work = SessionProject(id: "work", name: "Work", sessionIds: ["filed"])
    private let home = SessionProject(id: "home", name: "Home", sessionIds: [])
    private let plain = SessionSummary(id: "plain", title: "Plain")
    private let filed = SessionSummary(id: "filed", title: "Filed")
    private let pinned = SessionSummary(id: "pinned", title: "Pinned", isPinned: true)

    private func resolve(
      _ session: SessionSummary, in project: SessionProject? = nil, isShared: Bool = false,
      on target: SidebarDropTarget
    ) -> SidebarDropAction {
      SidebarDropAction.resolve(
        session: session, project: project, isShared: isShared, target: target)
    }

    @Test("A drag's payload names what it carries; anything else isn't ours")
    func payloads() {
      for item in [SidebarDragItem.session("a"), .project("b")] {
        #expect(SidebarDragItem(payload: item.payload) == item)
      }
      #expect(SidebarDragItem(payload: "https://example.test") == nil)
      #expect(SidebarDragItem(payload: "") == nil)
    }

    @Test("Onto a project: files it, unpinning a pin; shared and same-folder drops do nothing")
    func ontoProject() {
      #expect(resolve(plain, on: .project(work)) == .move(to: work, unpin: false))
      #expect(resolve(pinned, on: .project(work)) == .move(to: work, unpin: true))
      #expect(resolve(filed, in: work, on: .project(home)) == .move(to: home, unpin: false))
      #expect(resolve(filed, in: work, on: .project(work)) == .none)
      #expect(resolve(plain, isShared: true, on: .project(work)) == .none)
      // A pin filed here is pulled out of Pinned so it shows in the folder.
      #expect(resolve(pinned, in: work, on: .project(work)) == .move(to: work, unpin: true))
    }

    @Test("Onto Pinned: pins unless it's pinned, can't pin, or is archived")
    func ontoPinned() {
      #expect(resolve(plain, on: .pinned) == .pin(slotOf: nil))
      #expect(resolve(pinned, on: .pinned) == .none)
      var cannotPin = plain
      cannotPin.canPin = false
      #expect(resolve(cannotPin, on: .pinned) == .none)
      var archived = plain
      archived.isArchived = true
      #expect(resolve(archived, on: .pinned) == .none)
    }

    @Test("Onto a pinned row: takes its slot, unless it's the same row")
    func ontoPinSlot() {
      #expect(resolve(plain, on: .pinSlot("other")) == .pin(slotOf: "other"))
      #expect(resolve(pinned, on: .pinSlot("other")) == .pin(slotOf: "other"))
      #expect(resolve(pinned, on: .pinSlot("pinned")) == .none)
      var cannotPin = plain
      cannotPin.canPin = false
      #expect(resolve(cannotPin, on: .pinSlot("other")) == .none)
      var archived = plain
      archived.isArchived = true
      #expect(resolve(archived, on: .pinSlot("other")) == .none)
    }

    @Test("Onto Sessions: leaves its project; a shared one can only lose its pin")
    func ontoSessions() {
      #expect(resolve(filed, in: work, on: .sessions) == .ungroup(unpin: false))
      #expect(resolve(pinned, in: work, on: .sessions) == .ungroup(unpin: true))
      #expect(resolve(pinned, on: .sessions) == .unpin)
      #expect(resolve(plain, on: .sessions) == .none)
      #expect(resolve(filed, in: work, isShared: true, on: .sessions) == .none)
      #expect(resolve(pinned, in: work, isShared: true, on: .sessions) == .unpin)
    }

    @Test("Reordering puts a project at the target's place; nothing happens if either is gone")
    func reorder() {
      let third = SessionProject(id: "third", name: "Third", sessionIds: [])
      let projects = [work, home, third]
      let toEnd = SessionProject.reordered(projects, moving: "work", onto: "third")
      #expect(toEnd.map(\.id) == ["home", "third", "work"])
      let toStart = SessionProject.reordered(projects, moving: "third", onto: "work")
      #expect(toStart.map(\.id) == ["third", "work", "home"])
      #expect(SessionProject.reordered(projects, moving: "work", onto: "work").isEmpty)
      #expect(SessionProject.reordered(projects, moving: "gone", onto: "work").isEmpty)
      #expect(SessionProject.reordered(projects, moving: "work", onto: "gone").isEmpty)
    }

    private func handler(
      _ spy: SidebarSpy, edit: (inout SidebarViewState) -> Void = { _ in }
    ) -> SidebarDropHandler {
      var state = SidebarViewState(list: SessionListViewState(sessions: [plain, filed, pinned]))
      state.projects = [work, home]
      edit(&state)
      return SidebarDropHandler(state: state, actions: spy.actions)
    }

    @Test("Row and header targets follow the section, and only the default grouping has them")
    func targets() {
      let spy = SidebarSpy(SidebarFixture.state)
      let sessions = SidebarSections.Section(
        title: "Sessions", sessions: [], showsDisplayMenu: true)
      let pins = SidebarSections.Section(title: "Pinned", sessions: [], isPinned: true)
      let other = SidebarSections.Section(title: "Other", sessions: [])
      let handler = handler(spy)
      #expect(handler.rowTarget(pinned, in: pins) == .pinSlot("pinned"))
      #expect(handler.rowTarget(plain, in: sessions) == .sessions)
      #expect(handler.rowTarget(plain, in: other) == nil)
      #expect(handler.sectionTarget(pins) == .pinned)
      #expect(handler.sectionTarget(sessions) == .sessions)
      #expect(handler.sectionTarget(other) == nil)

      let grouped = self.handler(spy) { $0.display.groupBy = .status }
      #expect(grouped.rowTarget(plain, in: sessions) == nil)
      #expect(grouped.sectionTarget(sessions) == nil)
      // Pinned rows and the Pinned header accept drops under any grouping.
      #expect(grouped.rowTarget(pinned, in: pins) == .pinSlot("pinned"))
      #expect(grouped.sectionTarget(pins) == .pinned)
    }

    @Test("Dropping a project onto another reorders them")
    func dropProject() {
      let spy = SidebarSpy(SidebarFixture.state)
      let handler = handler(spy)
      #expect(handler.drop(.project("home"), on: .project(work)))
      #expect(spy.calls == ["reorder home,work"])
      spy.calls = []
      #expect(!handler.drop(.project("home"), on: .project(home)))
      #expect(!handler.drop(.project("home"), on: .pinned))
      #expect(spy.calls.isEmpty)
    }

    @Test("Dropping a session carries out what it resolves to")
    func dropSession() {
      let spy = SidebarSpy(SidebarFixture.state)
      let handler = handler(spy)
      #expect(handler.drop(.session("plain"), on: .project(work)))
      #expect(handler.drop(.session("filed"), on: .sessions))
      #expect(spy.calls.count == 2)
      #expect(spy.calls[0].hasPrefix("drop plain "))
      #expect(spy.calls[1].hasPrefix("drop filed "))
      spy.calls = []
      #expect(!handler.drop(.session("gone"), on: .sessions))
      #expect(!handler.drop(.session("plain"), on: .sessions))
      #expect(spy.calls.isEmpty)
    }

    @Test("A shared session is told apart by its row's facts")
    func dropShared() {
      let spy = SidebarSpy(SidebarFixture.state)
      let handler = handler(spy) { $0.rowInfo = ["plain": SessionRowInfo(isShared: true)] }
      #expect(!handler.drop(.session("plain"), on: .project(work)))
      #expect(spy.calls.isEmpty)
    }

    @Test("Pinning past the limit is refused; moving an existing pin isn't")
    func pinLimit() {
      let spy = SidebarSpy(SidebarFixture.state)
      let full = handler(spy) { $0.pinLimit = 1 }
      #expect(!full.drop(.session("plain"), on: .pinned))
      #expect(spy.calls.isEmpty)
      #expect(full.drop(.session("pinned"), on: .pinSlot("other")))
      #expect(spy.calls.count == 1)
    }

    @Test("Without the host's actions, drops do nothing")
    func noActions() {
      var actions = SidebarSpy(SidebarFixture.state).actions
      actions.dropSession = nil
      actions.reorderProjects = nil
      var state = SidebarViewState(list: SessionListViewState(sessions: [plain]))
      state.projects = [work, home]
      let handler = SidebarDropHandler(state: state, actions: actions)
      #expect(!handler.drop(.session("plain"), on: .project(work)))
      #expect(!handler.drop(.project("home"), on: .project(work)))
    }
  }
#endif
