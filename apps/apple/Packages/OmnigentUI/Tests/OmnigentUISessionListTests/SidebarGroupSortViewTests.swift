#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Three pins, a project of three and a project of one, with one loose session.
  @MainActor
  enum GroupSortFixture {
    static let work = SessionProject(id: "work", name: "Work", sessionIds: ["w1", "w2", "w3"])
    static let home = SessionProject(id: "home", name: "Home", sessionIds: ["h1"])

    static var state: SidebarViewState {
      let pins = [("p1", "Cherry"), ("p2", "Apple"), ("p3", "Banana")].map {
        SessionSummary(id: $0.0, title: $0.1, isPinned: true)
      }
      let rest = [("w1", "Walnut"), ("w2", "Almond"), ("w3", "Pecan"), ("h1", "Hazel")].map {
        SessionSummary(id: $0.0, title: $0.1)
      }
      let loose = SessionSummary(id: "loose", title: "Loose")
      var state = SidebarViewState(list: SessionListViewState(sessions: pins + rest + [loose]))
      state.projects = [work, home]
      return state
    }

    /// Rows with Work open: 5 Pinned header, 6 to 8 the pins, 9 Projects header, 10 Work,
    /// 11 to 13 its sessions, 14 Home, 15 Sessions header, 16 loose.
    static func openSpy(_ edit: (inout SidebarViewState) -> Void = { _ in }) -> SidebarSpy {
      var state = state
      edit(&state)
      let spy = SidebarSpy(state)
      UserDefaults.standard.set("work", forKey: SidebarNavigationOrder.expandedProjectsKey)
      return spy
    }
    static let pinnedHeader = 5
    static let firstPin = 6
    static let workFolder = 10
    static let firstWorkRow = 11
    static let looseRow = 16
  }

  @Suite("Sidebar group sort: a drop within a group")
  @MainActor
  struct SidebarGroupSortDropTests {
    private let work = GroupSortFixture.work

    private func handler(
      _ spy: SidebarSpy, actions: SidebarActions? = nil,
      edit: (inout SidebarViewState) -> Void = { _ in }
    ) -> SidebarDropHandler {
      var state = spy.state
      edit(&state)
      return SidebarDropHandler(state: state, actions: actions ?? spy.actions)
    }

    @Test("A pin dropped on another pin takes its place in the order on screen")
    func pinOntoPin() {
      let spy = SidebarSpy(GroupSortFixture.state)
      #expect(handler(spy).drop(.session("p3"), on: .pinSlot("p1")))
      #expect(spy.calls == ["order pinned p3,p1,p2"])

      // Sorted by name the rows read Apple, Banana, Cherry, and the drop starts from that.
      spy.calls = []
      let byName = handler(spy) { $0.groupSorts.chosen[SessionGroup.pinned.key] = .name }
      #expect(byName.drop(.session("p1"), on: .pinSlot("p2")))
      #expect(spy.calls == ["order pinned p1,p2,p3"])
    }

    @Test("A session dropped on a row of its own project takes that row's place")
    func withinAProject() {
      let spy = SidebarSpy(GroupSortFixture.state)
      let handler = handler(spy)
      #expect(handler.drop(.session("w3"), on: .projectSlot(work, "w1")))
      #expect(spy.calls == ["order project:work w3,w1,w2"])
      spy.calls = []
      #expect(!handler.drop(.session("w1"), on: .projectSlot(work, "w1")), "its own row")
      #expect(!handler.drop(.session("w1"), on: .project(work)), "the folder it is in")
      #expect(spy.calls.isEmpty)
    }

    @Test("A session from elsewhere still pins into the slot or files into the project")
    func fromOutsideTheGroup() {
      let spy = SidebarSpy(GroupSortFixture.state)
      let handler = handler(spy)
      #expect(handler.drop(.session("loose"), on: .pinSlot("p2")))
      #expect(handler.drop(.session("h1"), on: .projectSlot(work, "w1")))
      #expect(handler.drop(.session("p1"), on: .projectSlot(work, "w1")))
      #expect(
        spy.calls == [
          "drop loose pin(slotOf: Optional(\"p2\"))",
          "drop h1 \(SidebarDropAction.move(to: work, unpin: false))",
          "drop p1 \(SidebarDropAction.move(to: work, unpin: true))",
        ])
    }

    @Test("Without the host's reorder a pin still moves into the slot, and no row offers Reorder")
    func withoutReorder() {
      let spy = SidebarSpy(GroupSortFixture.state)
      var actions = spy.actions
      actions.reorderGroup = nil
      let handler = handler(spy, actions: actions)
      #expect(handler.drop(.session("p3"), on: .pinSlot("p1")))
      #expect(spy.calls == ["drop p3 pin(slotOf: Optional(\"p1\"))"])
      #expect(handler.move(in: .pinned) == nil)
    }

    @Test("Only a pinned row and a project's row name a group whose rows change places")
    func targetGroups() {
      #expect(SidebarDropTarget.pinSlot("p1").group == .pinned)
      #expect(SidebarDropTarget.projectSlot(work, "w1").group == .project("work"))
      for target in [SidebarDropTarget.project(work), .pinned, .sessions] {
        #expect(target.group == nil)
      }
      let session = SessionSummary(id: "loose", title: "Loose")
      let resolve = { (target: SidebarDropTarget) in
        SidebarDropAction.resolve(session: session, project: nil, isShared: false, target: target)
      }
      #expect(resolve(.projectSlot(work, "w1")) == resolve(.project(work)))
    }

    @Test("A row's Reorder menu lists its group's rows and saves their new order")
    func rowMove() throws {
      let spy = SidebarSpy(GroupSortFixture.state)
      let handler = handler(spy)
      #expect(handler.move(in: nil) == nil)
      #expect(handler.move(in: .project("home")) == nil, "a group of one")
      #expect(handler.move(in: .project("gone")) == nil)
      let move = try #require(handler.move(in: .project("work")))
      #expect(move.rows().map(\.id) == ["w1", "w2", "w3"])
      move.save(move.rows().reversed())
      #expect(spy.calls == ["order project:work w3,w2,w1"])
    }
  }

  @Suite("Sidebar group sort: the sidebar's menus and rows", .serialized)
  @MainActor
  struct SidebarGroupSortViewTests {
    private func sidebar(_ spy: SidebarSpy) -> OffscreenWindow<SidebarHarness> {
      OffscreenWindow(SidebarHarness(spy: spy), width: 320, height: 900)
    }

    /// What the sidebar asked for, without the open folder's page read.
    private func asked(_ spy: SidebarSpy) -> [String] {
      spy.calls.filter { !$0.hasPrefix("load project") }
    }

    @Test("The Pinned header's menu checks the sort in effect and chooses another")
    func pinnedHeaderMenu() throws {
      let spy = GroupSortFixture.openSpy()
      let screen = sidebar(spy)
      defer { screen.close() }
      let popUp = try #require(try screen.popUps(inRow: GroupSortFixture.pinnedHeader).first)
      let menu = try screen.openMenu(popUp)
      for sort in SessionGroupSort.allCases {
        #expect(menu.item(named: sort.title)?.state == (sort == .custom ? .on : .off), "\(sort)")
      }
      try screen.choose(SessionGroupSort.name.title, in: menu)
      #expect(asked(spy) == ["sort pinned name"])

      spy.state.groupSorts.chosen[SessionGroup.pinned.key] = .name
      screen.settle()
      let again = try screen.openMenu(
        try #require(try screen.popUps(inRow: GroupSortFixture.pinnedHeader).first))
      #expect(again.item(named: SessionGroupSort.name.title)?.state == .on)
      try screen.choose(SessionGroupSort.name.title, in: again)
      #expect(asked(spy) == ["sort pinned name"], "choosing the sort in effect asks nothing")
    }

    @Test("A project's menu sorts that project's sessions, and no other group's")
    func projectMenu() throws {
      let spy = GroupSortFixture.openSpy {
        $0.groupSorts.chosen[SessionGroup.project("home").key] = .name
      }
      let screen = sidebar(spy)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: GroupSortFixture.workFolder))
      let sorts = try #require(menu.item(named: "Sort sessions by")?.submenu)
      #expect(sorts.item(named: SessionGroupSort.recent.title)?.state == .on)
      #expect(sorts.item(named: SessionGroupSort.name.title)?.state == .off)
      try screen.choose(SessionGroupSort.custom.title, in: sorts)
      #expect(asked(spy) == ["sort project:work custom"])
    }

    @Test("A row's Reorder moves it within its group; the top row cannot move up")
    func rowReorderMenu() throws {
      let spy = GroupSortFixture.openSpy()
      let screen = sidebar(spy)
      defer { screen.close() }
      let pinMenu = try #require(try screen.menu(ofRow: GroupSortFixture.firstPin))
      let reorder = try #require(pinMenu.item(named: "Reorder")?.submenu)
      pinMenu.update()
      reorder.update()
      #expect(reorder.titles == ProjectMove.allCases.map(\.title))
      #expect(reorder.item(named: ProjectMove.upOne.title)?.isEnabled == false)
      #expect(reorder.item(named: ProjectMove.downOne.title)?.isEnabled == true)
      try screen.choose(ProjectMove.downOne.title, in: reorder)
      #expect(asked(spy) == ["order pinned p2,p1,p3"])

      spy.calls = []
      let rowMenu = try #require(try screen.menu(ofRow: GroupSortFixture.firstWorkRow))
      try screen.choose(
        ProjectMove.bottom.title, in: try #require(rowMenu.item(named: "Reorder")?.submenu))
      #expect(asked(spy) == ["order project:work w2,w3,w1"])

      let loose = try #require(try screen.menu(ofRow: GroupSortFixture.looseRow))
      #expect(loose.item(named: "Reorder") == nil, "the Sessions list keeps the list's order")
    }

    @Test("The rows show in each group's order, and follow a new sort")
    func rowsFollowTheSort() throws {
      let spy = GroupSortFixture.openSpy {
        $0.groupSorts = SessionGroupSorts(
          chosen: [SessionGroup.pinned.key: .name, SessionGroup.project("work").key: .custom],
          customOrder: [SessionGroup.project("work").key: ["w3", "w1", "w2"]])
      }
      let screen = sidebar(spy)
      defer { screen.close() }
      let titles = ["Cherry", "Apple", "Banana", "Walnut", "Almond", "Pecan"]
      let rows = [6, 7, 8, 11, 12, 13]
      let list = try #require(screen.list)
      let shown = {
        try rows.map { row in
          let view = try #require(list.rowView(atRow: row, makeIfNecessary: false))
          return try screen.shownText(under: view).first(where: titles.contains)
        }
      }
      #expect(try shown() == ["Apple", "Banana", "Cherry", "Pecan", "Walnut", "Almond"])

      spy.state.groupSorts.chosen = [SessionGroup.project("work").key: .name]
      screen.settle()
      #expect(try shown() == ["Cherry", "Apple", "Banana", "Almond", "Pecan", "Walnut"])
    }

    @Test("A row dragged onto a row of its group asks for the group's new order")
    func dragWithinAGroup() async throws {
      let spy = GroupSortFixture.openSpy()
      let screen = sidebar(spy)
      defer { screen.close() }
      try await screen.drop(
        SidebarDragItem.session("p3").payload,
        at: try screen.center(ofRow: GroupSortFixture.firstPin))
      try await screen.drop(
        SidebarDragItem.session("w2").payload,
        at: try screen.center(ofRow: GroupSortFixture.firstWorkRow))
      #expect(asked(spy) == ["order pinned p3,p1,p2", "order project:work w2,w1,w3"])
    }

    @Test("While selecting sessions the Pinned header offers no sort")
    func hiddenWhileSelecting() throws {
      let spy = GroupSortFixture.openSpy()
      let screen = sidebar(spy)
      defer { screen.close() }
      #expect(try screen.popUps(inRow: GroupSortFixture.pinnedHeader).count == 1)
      try screen.click(try screen.plainButtons(inRow: 15)[1])
      #expect(try screen.popUps(inRow: GroupSortFixture.pinnedHeader).isEmpty)
    }
  }
#endif
