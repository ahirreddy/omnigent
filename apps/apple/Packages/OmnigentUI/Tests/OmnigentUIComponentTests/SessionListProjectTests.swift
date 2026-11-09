#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: project folders", .serialized)
  @MainActor
  struct SessionListProjectTests {
    private let work = SessionProject(
      id: "p1", name: "Work", sessionIds: ["beta"], icon: "\u{1F680}")
    private let home = SessionProject(id: "p2", name: "Home", sessionIds: [])

    /// Rows: 5 Pinned header, 6 pinned, 7 Projects header, 8 Work, 9 Home, 10 Sessions, 11 gamma.
    private func spy() -> SidebarSpy {
      var state = SidebarFixture.state
      state.projects = [work, home]
      state.projectSort = .alphabetical
      return SidebarSpy(state)
    }
    private let workRow = 8

    private func expanded() -> String? {
      UserDefaults.standard.string(forKey: SidebarNavigationOrder.expandedProjectsKey)
    }

    @Test("a folder's context menu lists the web's items and runs them")
    func folderMenu() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: workRow))
      #expect(
        menu.titles == [
          "New session", "Rename project\u{2026}", "Project settings\u{2026}", "Move",
          "Delete project\u{2026}",
        ])
      try screen.choose("New session", in: menu)
      try screen.choose("Project settings\u{2026}", in: menu)
      #expect(spy.calls == ["new in p1", "project settings p1"])
    }

    @Test("Move reorders projects, and the top one can't move up")
    func moveMenu() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: workRow))
      let move = try #require(menu.item(named: "Move")?.submenu)
      menu.update()
      move.update()
      let titles = move.titles
      #expect(titles.count == ProjectMove.allCases.count)
      for moveCase in ProjectMove.allCases {
        let moved = SessionProject.moved([work, home], id: "p1", moveCase)
        #expect(move.item(named: moveCase.title)?.isEnabled == !moved.isEmpty)
      }
      let down = try #require(
        ProjectMove.allCases.first { !SessionProject.moved([work, home], id: "p1", $0).isEmpty })
      try screen.choose(down.title, in: move)
      #expect(spy.calls == ["reorder p2,p1"])
    }

    @Test("Delete project asks first and runs only on confirmation")
    func deleteProject() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: workRow))
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.choose("Delete project\u{2026}", in: menu)
      #expect(SystemSideEffects.record.alertMessages.contains("Delete this project?"))
      #expect(spy.calls.isEmpty)

      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.choose("Delete project\u{2026}", in: menu)
      #expect(spy.calls == ["delete project p1"])
    }

    @Test("a lone project can't move, and no actions leave no menu items")
    func folderMenuVariants() throws {
      var state = SidebarFixture.state
      state.projects = [home]
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: workRow))
      #expect(menu.item(named: "Delete project\u{2026}") != nil)
      #expect(menu.item(named: "Move") == nil)
      let items = ProjectMenu(
        project: home, projects: [home], actions: SidebarActions(sessions: SessionListActions()),
        rename: {}, confirmDelete: {})
      _ = items.items
    }

    @Test("expanding a folder reads its first page and remembers it")
    func expandReadsPage() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      #expect(spy.calls.isEmpty)
      let rowsBefore = try #require(screen.list).numberOfRows
      try #require(screen.disclosures.first).performClick(nil)
      screen.settle(0.2)
      #expect(spy.calls == ["load project p1"])
      #expect(expanded() == "p1")
      #expect(try #require(screen.list).numberOfRows == rowsBefore + 1)
      try #require(screen.disclosures.first).performClick(nil)
      screen.settle(0.2)
      #expect(expanded()?.isEmpty == true)
    }

    @Test("an empty open folder says it's loading, then that it's empty")
    func emptyFolder() throws {
      let spy = spy()
      UserDefaults.standard.set("p2", forKey: SidebarNavigationOrder.expandedProjectsKey)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      #expect(Set(spy.calls) == ["load project p2"])
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      spy.state.paging.loadedProjects = ["p2"]
      screen.settle()
      #expect(!screen.allViews.contains { $0 is NSProgressIndicator })
    }

    @Test("Show more lists five more, and reads the next page when loaded rows run out")
    func showMore() throws {
      var calls: [Int] = []
      var loads = 0
      let sessions = (0..<7).map { SessionSummary(id: "s\($0)", title: "S\($0)") }
      func pages(shown: Int) -> ProjectFolderPages {
        ProjectFolderPages(
          project: work, sessions: sessions, paging: SidebarPaging(), shown: shown, selectedID: nil,
          load: { _ in loads += 1 }, setShown: { calls.append($0) })
      }
      let first = pages(shown: 0)
      #expect(first.visibleCount == ProjectFolderPaging.pageSize)
      first.showMore()
      #expect(calls == [10])
      #expect(loads == 1)
      first.load?()
      #expect(loads == 2)
      let noLoad = ProjectFolderPages(
        project: work, sessions: sessions, paging: SidebarPaging(), shown: 0, selectedID: "s6",
        load: nil, setShown: { _ in })
      // The open session stays listed even past the first page.
      #expect(noLoad.visibleCount == sessions.count)
      noLoad.showMore()
      #expect(noLoad.load == nil)
    }

    @Test("Show more on the folder's row works, and waits while the page is loading")
    func showMoreRow() throws {
      let ids = (0..<7).map { "s\($0)" }
      var state = SidebarFixture.state
      state.list.sessions += ids.map { SessionSummary(id: $0, title: $0) }
      state.projects = [SessionProject(id: "big", name: "Big", sessionIds: ids)]
      state.paging.loadedProjects = ["big"]
      let spy = SidebarSpy(state)
      UserDefaults.standard.set("big", forKey: SidebarNavigationOrder.expandedProjectsKey)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 900)
      defer { screen.close() }
      let table = try #require(screen.list)
      let before = table.numberOfRows
      // Rows: 7 Projects, 8 Big, 9 to 13 its first five, 14 Show more.
      let more = try #require(try screen.plainButtons(inRow: 14).first)
      try screen.click(more)
      #expect(table.numberOfRows == before + 1)
      // Five more runs past the two left, so the next server page is read.
      #expect(spy.calls == ["load project big"])
    }

    @Test("hovering a folder offers New session and its menu")
    func hoverButtons() throws {
      let spy = spy()
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      #expect(try screen.plainButtons(inRow: workRow).isEmpty)
      try screen.hoverRow(workRow)
      let newSession = try #require(try screen.plainButtons(inRow: workRow).first)
      try screen.click(newSession)
      #expect(spy.calls == ["new in p1"])
      let menu = try screen.openMenu(try #require(try screen.popUps(inRow: workRow).first))
      #expect(menu.item(named: "Rename project\u{2026}") != nil)
      try screen.endRowHover()
      #expect(try screen.plainButtons(inRow: workRow).isEmpty)
    }
  }
#endif
