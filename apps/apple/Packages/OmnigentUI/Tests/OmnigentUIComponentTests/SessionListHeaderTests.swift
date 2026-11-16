#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: header, display menu and selection", .serialized)
  @MainActor
  struct SessionListHeaderTests {
    private func spyWithServers() -> SidebarSpy {
      var state = SidebarFixture.state
      state.servers = [
        ServerChoice(id: "org", name: "Corp", url: "https://corp.test", isOrganization: true),
        ServerChoice(id: "home", name: "Home", url: "https://home.test"),
      ]
      state.currentServerID = "home"
      return SidebarSpy(state)
    }

    @Test("the server menu switches, connects, opens settings and signs out")
    func serverMenu() throws {
      let spy = spyWithServers()
      let screen = OffscreenWindow(
        SidebarHeader(state: spy.state, actions: spy.actions), width: 300, height: 60)
      defer { screen.close() }
      let menu = try screen.openMenu(try #require(screen.popUps.first))
      for title in ["Corp", "Home", "Connect to New Server\u{2026}", "Server Settings\u{2026}"] {
        #expect(menu.item(named: title) != nil, "\(title)")
      }
      try screen.choose("Corp", in: menu)
      try screen.choose("Connect to New Server\u{2026}", in: menu)
      try screen.choose("Server Settings\u{2026}", in: menu)
      try screen.choose("Sign Out of Home", in: menu)
      #expect(spy.calls == ["server org", "add server", "server settings", "sign out"])
    }

    @Test(
      "the Omnigent wordmark starts a new session; Search opens the palette; the gear opens Settings"
    )
    func headerButtons() throws {
      let spy = spyWithServers()
      var opened: [String] = []
      let presenter = PalettePresenter()
      presenter.open = { opened.append("palette") }
      let settings = SettingsScreenPresenter()
      settings.open = { opened.append("settings") }
      let screen = OffscreenWindow(
        SidebarHeader(state: spy.state, actions: spy.actions)
          .environment(\.openCommandPalette, OpenCommandPaletteAction(presenter: presenter))
          .environment(\.openSettingsPage, OpenSettingsScreenAction(presenter: settings)),
        width: 300, height: 60)
      defer { screen.close() }
      // Wordmark, server menu, Search, Settings.
      #expect(screen.controlFrames.count == 4)
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["new session"])
      try screen.clickControl(at: 2)
      #expect(opened == ["palette"])
      try screen.clickControl(at: 3)
      #expect(opened == ["palette", "settings"])
    }

    @Test("without actions the header is just its wordmark and Settings, where a window has it")
    func bareHeader() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let actions = SidebarActions(sessions: SessionListActions())
      let screen = OffscreenWindow(
        SidebarHeader(state: spy.state, actions: actions)
          .environment(
            \.openSettingsPage, OpenSettingsScreenAction(presenter: SettingsScreenPresenter())),
        width: 300, height: 60)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 1)

      // No Settings page to open (a preview, the gallery): no gear.
      let plain = OffscreenWindow(
        SidebarHeader(state: spy.state, actions: actions), width: 300, height: 60)
      defer { plain.close() }
      #expect(plain.controlFrames.isEmpty)
    }

    @Test("the display menu's pickers and row details each write their one option")
    func displayMenu() throws {
      var written: [SessionDisplayOptions] = []
      let options = SessionDisplayOptions()
      let screen = OffscreenWindow(
        DisplayMenu(options: options, showsShared: false) { written.append($0) }, width: 80,
        height: 40)
      defer { screen.close() }
      let menu = try screen.openMenu(try #require(screen.popUps.first))
      #expect(menu.item(named: SessionShowScope.shared.title) == nil)
      try screen.choose(SessionShowScope.archived.title, in: menu)
      #expect(written.last?.show == .archived)
      let grouping = try #require(SessionGrouping.allCases.first { $0 != options.groupBy })
      try screen.choose(grouping.title, in: menu)
      #expect(written.last?.groupBy == grouping)
      #expect(written.last?.show == options.show)
      let sort = try #require(SessionSort.allCases.first { $0 != options.sortBy })
      try screen.choose(sort.title, in: try #require(menu.item(named: "Ordering")?.submenu))
      #expect(written.last?.sortBy == sort)
      let detail = try #require(SessionRowDetail.allCases.first)
      try screen.choose(detail.title, in: try #require(menu.item(named: "Show")?.submenu))
      #expect(written.last?.details.contains(detail) != options.details.contains(detail))
    }

    @Test("Select sessions turns clicks into checks, and the bar acts on them")
    func selectionFlow() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      // Sessions header: New session, Select sessions; then the display menu.
      let header = try screen.plainButtons(inRow: 9)
      try screen.click(header[0])
      #expect(spy.calls == ["new session"])
      try screen.click(try screen.plainButtons(inRow: 9)[1])
      let selectedBefore = spy.selection
      try screen.clickRow(SidebarFixture.betaRow)
      try screen.clickRow(SidebarFixture.gammaRow)
      #expect(spy.selection == selectedBefore)
      // Exit, Mark as unread, Archive, Delete, at the end of the window's controls.
      let frames = screen.controlFrames
      let archive = frames[frames.count - 2]
      try screen.click(CGPoint(x: archive.midX, y: archive.midY))
      #expect(spy.calls.last == "archive many beta,gamma true")

      // A navigation row leaves selection, and opens as usual.
      try screen.clickRow(1)
      #expect(spy.selection == .inbox)
      #expect(try screen.plainButtons(inRow: 9).count == 2)
    }

    @Test("Escape leaves selection, and changing Display does too")
    func leavingSelection() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      try screen.click(try screen.plainButtons(inRow: 9)[1])
      try screen.clickRow(SidebarFixture.betaRow)
      #expect(try screen.plainButtons(inRow: 9).isEmpty)
      #expect(spy.selection == nil, "the click checked the row")
      try screen.press(keyCode: 53, characters: "\u{1B}")
      #expect(try screen.plainButtons(inRow: 9).count == 2)
      // Out of selection a click opens the row again.
      try screen.clickRow(SidebarFixture.gammaRow)
      #expect(spy.selection == .session("gamma"))

      try screen.click(try screen.plainButtons(inRow: 9)[1])
      #expect(try screen.plainButtons(inRow: 9).isEmpty)
      spy.state.display.show = .archived
      screen.settle()
      #expect(try screen.plainButtons(inRow: 9).count == 2)
    }

    @Test("Down and Up move the open session through the rows")
    func arrowKeys() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      try screen.clickRow(SidebarFixture.betaRow)
      #expect(spy.selection == .session("beta"))
      let arrowKeys: NSEvent.ModifierFlags = [.function, .numericPad]
      try screen.press(keyCode: 125, characters: "\u{F701}", modifiers: arrowKeys)
      #expect(spy.selection == .session("gamma"))
      try screen.press(keyCode: 126, characters: "\u{F700}", modifiers: arrowKeys)
      #expect(spy.selection == .session("beta"))
    }

    @Test("bulk delete confirms, then clears what was checked")
    func bulkDelete() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      try screen.click(try screen.plainButtons(inRow: 9)[1])
      try screen.clickRow(SidebarFixture.betaRow)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      let delete = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: delete.midX, y: delete.midY))
      #expect(spy.calls == ["delete beta"])
    }

    @Test("Delete archives the open session")
    func deleteKey() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      spy.selection = .session("beta")
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      try screen.press(keyCode: 51, characters: "\u{7F}")
      // With the system's keyboard navigation on (a CI image's setting) the list has the keyboard
      // and takes the key. Without it onDeleteCommand comes only from the Edit menu, which no
      // offscreen window has.
      withKnownIssue("Delete reaches an offscreen list only with keyboard navigation on") {
        #expect(spy.calls == ["archive beta true"])
      } when: {
        !NSApp.isFullKeyboardAccessEnabled
      }
    }

    @Test("a search collapses sections only for itself")
    func searchCollapse() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 340, height: 800)
      defer { screen.close() }
      spy.search = "be"
      screen.settle()
      let before = try #require(screen.list).numberOfRows
      screen.sectionToggles[2].performClick(nil)
      #expect(MainLoop.settle(until: { (screen.list?.numberOfRows ?? before) < before }))
      #expect(
        UserDefaults.standard.string(forKey: SidebarNavigationOrder.collapsedSectionsKey) == nil)
      screen.sectionToggles[2].performClick(nil)
      #expect(MainLoop.settle(until: { screen.list?.numberOfRows == before }))
    }
  }
#endif
