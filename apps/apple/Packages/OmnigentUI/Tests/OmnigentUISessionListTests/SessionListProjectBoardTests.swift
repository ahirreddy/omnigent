#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  @Suite("Sidebar: project rows with boards", .serialized)
  @MainActor
  struct SessionListProjectBoardTests {
    /// Rows: 5 Pinned header, 6 pinned, 7 Projects header, 8 Work, 9 Home, 10 Sessions, 11 gamma.
    private func spy(boards: Bool) -> SidebarSpy {
      var state = SidebarFixture.state
      state.projects = [
        SessionProject(id: "p1", name: "Work", sessionIds: ["beta"]),
        SessionProject(id: "p2", name: "Home", sessionIds: []),
      ]
      state.projectSort = .alphabetical
      state.projectBoards = boards
      return SidebarSpy(state)
    }
    private let workRow = 8

    private func expanded() -> String? {
      UserDefaults.standard.string(forKey: SidebarNavigationOrder.expandedProjectsKey)
    }

    @Test("a folder's row opens its board and only its button shows or hides its sessions")
    func rowOpensBoard() throws {
      let spy = spy(boards: true)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      try screen.clickRow(workRow)
      #expect(spy.selection == .project("p1"))
      #expect(expanded()?.contains("p1") != true, "opening the board leaves the folder closed")
      let rowsBefore = try #require(screen.list).numberOfRows
      try screen.clickListElement("sidebar-project-toggle-p1")
      #expect(MainLoop.settle(until: { screen.list?.numberOfRows == rowsBefore + 1 }))
      #expect(expanded() == "p1")
      #expect(spy.selection == .project("p1"), "the button leaves the board open")
      try screen.clickListElement("sidebar-project-toggle-p1")
      #expect(MainLoop.settle(until: { expanded()?.isEmpty == true }))
    }

    @Test("without boards, or with them off in Settings, the row shows or hides the sessions")
    func rowTogglesWithoutBoards() throws {
      let key = InterfacePreferences.projectBoardKey
      for (boards, preference) in [(false, true), (true, false)] {
        UserDefaults.standard.set(preference, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let spy = spy(boards: boards)
        let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
        defer { screen.close() }
        try screen.clickRow(workRow)
        #expect(MainLoop.settle(until: { expanded() == "p1" }), "boards \(boards)")
        #expect(spy.selection != .project("p1"))
      }
    }
  }
#endif
