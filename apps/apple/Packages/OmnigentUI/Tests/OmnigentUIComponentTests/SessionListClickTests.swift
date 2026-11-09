#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: clicks open what they say", .serialized)
  @MainActor
  struct SessionListClickTests {
    @Test("clicking a session row opens that session")
    func clickOpensSession() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      try screen.clickRow(SidebarFixture.betaRow)
      #expect(spy.selection == .session("beta"))
      try screen.clickRow(SidebarFixture.gammaRow)
      #expect(spy.selection == .session("gamma"))
      try screen.clickRow(SidebarFixture.pinnedRow)
      #expect(spy.selection == .session("pinned"))
    }

    @Test("the navigation rows open their pages, and only the ones the server offers show")
    func navigationRows() throws {
      var state = SidebarFixture.state
      state.showsAutomations = true
      state.showsUsage = true
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 800)
      defer { screen.close() }
      let destinations: [SidebarDestination] = [.newSession, .automations, .inbox, .canvas, .usage]
      for (row, destination) in destinations.enumerated() {
        try screen.selectRow(row)
        #expect(spy.selection == destination)
      }
      let rowsWithAll = try #require(screen.list).numberOfRows
      spy.state.showsAutomations = false
      spy.state.showsUsage = false
      spy.state.showsCanvas = false
      screen.settle()
      #expect(try #require(screen.list).numberOfRows == rowsWithAll - 3)
    }

    @Test("a quick filter row turns on, and clicking it again turns it off")
    func quickFilters() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      try screen.clickRow(3)
      try screen.clickRow(4)
      #expect(spy.calls == ["filter running", "filter needsResponse"])
      spy.calls = []
      spy.state.quickFilter = .running
      screen.settle()
      try screen.clickRow(3)
      #expect(spy.calls == ["filter none"])
      spy.calls = []
      spy.state.quickFilter = .needsResponse
      screen.settle()
      try screen.clickRow(4)
      #expect(spy.calls == ["filter none"])
    }

    @Test("without a quick filter action the filter rows are gone")
    func noQuickFilters() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      var actions = spy.actions
      actions.setQuickFilter = nil
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy, actions: actions), width: 300, height: 700)
      defer { screen.close() }
      // The same rows as the fixture, without Running and Needs you.
      #expect(try #require(screen.list).numberOfRows == 10)
    }

    @Test("Show All Sessions clears the filter that emptied the list")
    func showAllSessions() throws {
      for filter in [SessionFilter.running, .needsResponse] {
        var state = SidebarViewState(list: SessionListViewState(sessions: []))
        state.quickFilter = filter
        let spy = SidebarSpy(state)
        let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
        defer { screen.close() }
        let list = try #require(screen.list)
        let last = list.numberOfRows - 1
        let frame = list.convert(list.rect(ofRow: last), to: screen.host)
        // The link sits on the row's second line, at its leading edge.
        try screen.click(CGPoint(x: frame.minX + 40, y: frame.maxY - 12))
        #expect(spy.calls == ["filter none"], "\(filter)")
      }
    }

    @Test("Retry under a failed list asks again")
    func retry() throws {
      var state = SidebarFixture.state
      state.list.phase = .failed(message: "No route to host")
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      // The error bar's button is the last control in the window.
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(spy.calls == ["retry"])
    }

    @Test("typing in the peek's search field reaches the host")
    func searchField() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy, isPeek: true), width: 300, height: 700)
      defer { screen.close() }
      let field = try #require(
        screen.allViews.first { $0 is NSTextField && ($0 as? NSTextField)?.isEditable == true })
      try screen.click(field)
      try screen.type("gam")
      #expect(spy.search == "gam")
    }

    @Test("the section's Hide button collapses it, and the choice survives")
    func collapseSection() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      let rows = try #require(screen.list).numberOfRows
      // Pinned, Projects, Sessions.
      let toggles = screen.sectionToggles
      #expect(toggles.count == 3)
      // AppKit shows these only while the pointer is over the header.
      toggles[2].performClick(nil)
      screen.settle(0.3)
      #expect(try #require(screen.list).numberOfRows == rows - 2)
      #expect(
        UserDefaults.standard.string(forKey: SidebarNavigationOrder.collapsedSectionsKey)
          == "Sessions")
      screen.sectionToggles[2].performClick(nil)
      screen.settle(0.3)
      #expect(try #require(screen.list).numberOfRows == rows)
      #expect(
        UserDefaults.standard.string(forKey: SidebarNavigationOrder.collapsedSectionsKey).isEmpty)
    }

    @Test("a new pin opens the collapsed Pinned section")
    func newPinOpensPinned() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      UserDefaults.standard.set("Pinned", forKey: SidebarNavigationOrder.collapsedSectionsKey)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      spy.state.list.sessions[1].isPinned = true
      screen.settle(0.3)
      #expect(
        UserDefaults.standard.string(forKey: SidebarNavigationOrder.collapsedSectionsKey).isEmpty)
    }

    @Test("Load more reads a page as it appears, up to three per scope, then on a click")
    func loadMore() throws {
      var state = SidebarFixture.state
      state.paging = SidebarPaging(hasMore: true)
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      #expect(spy.calls == ["load more"])
      let autoLoads = SidebarAutoLoads()
      #expect((0..<4).map { _ in autoLoads.take(in: "a") } == [true, true, true, false])
      #expect(autoLoads.take(in: "b"))
      let list = try #require(screen.list)
      try screen.click(try screen.center(ofRow: list.numberOfRows - 1))
      #expect(spy.calls == ["load more", "load more"])
    }

    @Test("Load more does nothing while a page is loading")
    func loadMoreWhileLoading() throws {
      var state = SidebarFixture.state
      state.paging = SidebarPaging(hasMore: true, isLoading: true)
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      let list = try #require(screen.list)
      try screen.click(try screen.center(ofRow: list.numberOfRows - 1))
      #expect(spy.calls.isEmpty)
    }

    @Test("Load more hides when every list section is collapsed")
    func loadMoreCollapsed() throws {
      var state = SidebarViewState(list: SessionListViewState(sessions: [SidebarFixture.beta]))
      state.paging = SidebarPaging(hasMore: true)
      let spy = SidebarSpy(state)
      UserDefaults.standard.set("Sessions", forKey: SidebarNavigationOrder.collapsedSectionsKey)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      #expect(spy.calls.isEmpty)
    }
  }
#endif
