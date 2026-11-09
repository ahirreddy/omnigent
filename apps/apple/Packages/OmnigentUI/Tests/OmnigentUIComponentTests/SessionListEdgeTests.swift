#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Session list: order and defaults")
  @MainActor
  struct SessionListOrderTests {
    @Test("Sorting by created puts the newest first, falling back to the update time")
    func sortedByCreated() {
      var state = SidebarViewState(
        list: SessionListViewState(sessions: [
          SessionSummary(id: "old", title: "Old", updatedAt: 500),
          SessionSummary(id: "new", title: "New", updatedAt: 1),
          SessionSummary(id: "noFacts", title: "No facts", updatedAt: 300),
          SessionSummary(id: "tied", title: "Tied", updatedAt: 1),
        ]))
      state.rowInfo = [
        "old": SessionRowInfo(createdAt: 100), "new": SessionRowInfo(createdAt: 900),
        "tied": SessionRowInfo(createdAt: 100),
      ]
      state.display.sortBy = .created
      let sessions = SidebarSections.sections(state).first { $0.showsDisplayMenu }?.sessions
      #expect(sessions?.map(\.id) == ["new", "noFacts", "old", "tied"])
    }

    @Test("Moving between sessions skips what the saved state keeps collapsed")
    func navigationOrderReadsDefaults() throws {
      let suite = "session-list-order"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let state = SidebarFixture.state
      #expect(
        SidebarNavigationOrder.sessionIDs(state, defaults: defaults) == ["pinned", "beta", "gamma"])
      #expect(SidebarNavigationOrder.pinnedIDs(state, defaults: defaults) == ["pinned"])

      defaults.set("Pinned", forKey: SidebarNavigationOrder.collapsedSectionsKey)
      #expect(SidebarNavigationOrder.sessionIDs(state, defaults: defaults) == ["beta", "gamma"])
      #expect(SidebarNavigationOrder.pinnedIDs(state, defaults: defaults).isEmpty)
    }

    @Test("The pinned list is empty when nothing's pinned")
    func noPinned() throws {
      let suite = "session-list-no-pins"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let state = SidebarViewState(
        list: SessionListViewState(sessions: [SidebarFixture.beta]))
      #expect(SidebarNavigationOrder.pinnedIDs(state, defaults: defaults).isEmpty)
    }
  }

  @Suite("Session list: rows, bars and menus", .serialized)
  @MainActor
  struct SessionListEdgeTests {
    private func sidebar(_ spy: SidebarSpy, actions: SidebarActions? = nil) -> OffscreenWindow<
      AnyView
    > {
      OffscreenWindow(AnyView(SidebarHarness(spy: spy, actions: actions)), width: 340, height: 800)
    }

    @Test("A menu Archive archives, and Unarchive puts it back")
    func menuArchive() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = sidebar(spy)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      try screen.choose("Archive", in: menu)
      #expect(spy.calls == ["archive beta true"])
    }

    @Test("Moving to a new project starts by naming it")
    func newProjectFromRow() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = sidebar(spy)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      try screen.choose("New project\u{2026}", in: menu)
      screen.settle(0.2)
      #expect(screen.activeWindow !== screen.window)
      // Filing waits for the name: nothing has moved yet.
      #expect(spy.calls.isEmpty)
    }

    @Test("A failed refresh keeps the list and offers Retry")
    func failedRefresh() throws {
      let spy = SidebarSpy(
        SidebarViewState(
          list: SessionListViewState(
            sessions: [SidebarFixture.beta], phase: .failed(message: "Couldn't refresh"))))
      let screen = sidebar(spy)
      defer { screen.close() }
      #expect(try screen.shows("Couldn't refresh"))
      #expect(try screen.shows("Beta"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(spy.calls == ["retry"])
    }

    @Test("A collapsed section shows the strongest thing hidden inside")
    func collapsedMarker() throws {
      var working = SidebarFixture.beta
      working.attention = .working
      let spy = SidebarSpy(
        SidebarViewState(list: SessionListViewState(sessions: [working, SidebarFixture.gamma])))
      let screen = sidebar(spy)
      defer { screen.close() }
      let spinners = { screen.allViews.filter { $0 is NSProgressIndicator }.count }
      let expanded = spinners()
      #expect(expanded >= 1)
      // Pinned isn't here, so Projects comes first and Sessions second.
      screen.sectionToggles[1].performClick(nil)
      screen.settle(0.3)
      #expect(try !screen.shows("Beta"))
      // The row's spinner went with it; the section header now has the marker's.
      #expect(spinners() >= 1)
    }

    @Test("A shown server menu has Appearance and Notifications, or one Settings screen")
    func settingsItems() throws {
      var state = SidebarFixture.state
      state.servers = [ServerChoice(id: "home", name: "Home", url: "https://home.test")]
      state.currentServerID = "home"
      let spy = SidebarSpy(state)
      var opened: [String] = []
      let appearance = AppearanceSettingsPresenter()
      appearance.open = { opened.append("appearance") }
      let notifications = NotificationSettingsPresenter()
      notifications.open = { opened.append("notifications") }
      let separate = OffscreenWindow(
        AnyView(
          SidebarHeader(state: spy.state, actions: spy.actions)
            .environment(
              \.openAppearanceSettings, OpenAppearanceSettingsAction(presenter: appearance)
            )
            .environment(
              \.openNotificationSettings, OpenNotificationSettingsAction(presenter: notifications))),
        width: 340, height: 60)
      defer { separate.close() }
      var menu = try separate.openMenu(#require(separate.popUps.first))
      try separate.choose("Appearance\u{2026}", in: menu)
      menu = try separate.openMenu(#require(separate.popUps.first))
      try separate.choose("Notifications\u{2026}", in: menu)
      #expect(opened == ["appearance", "notifications"])

      let screenPresenter = SettingsScreenPresenter()
      screenPresenter.open = { opened.append("settings") }
      let single = OffscreenWindow(
        AnyView(
          SidebarHeader(state: spy.state, actions: spy.actions)
            .environment(\.openSettingsScreen, OpenSettingsScreenAction(presenter: screenPresenter))
        ),
        width: 340, height: 60)
      defer { single.close() }
      menu = try single.openMenu(#require(single.popUps.first))
      #expect(menu.item(named: "Appearance\u{2026}") == nil)
      try single.choose("Settings\u{2026}", in: menu)
      #expect(opened.last == "settings")
    }

    @Test("A quick filter's badge shows only with something to count, and Needs You stands out")
    func filterBadges() throws {
      func row(_ filter: SessionFilter, count: Int?) -> OffscreenWindow<AnyView> {
        OffscreenWindow(
          AnyView(QuickFilterRow(filter: filter, isActive: false, count: count) {}), width: 300,
          height: 40)
      }
      let counted = row(.running, count: 3)
      defer { counted.close() }
      #expect(try counted.shows("3"))
      let zero = row(.running, count: 0)
      defer { zero.close() }
      #expect(try !zero.shows("0"))
      let none = row(.running, count: nil)
      defer { none.close() }
      #expect(try none.shows(SessionFilter.running.title))

      func picture(_ filter: SessionFilter) throws -> Data {
        try RenderSupport.picture(
          QuickFilterRow(filter: filter, isActive: false, count: 3) {}, width: 300, height: 40)
      }
      #expect(try picture(.needsResponse) != picture(.running))
    }

    @Test("The display menu offers Shared sessions unless the server has no sharing")
    func displayMenuDefault() throws {
      let screen = OffscreenWindow(
        AnyView(DisplayMenu(options: SessionDisplayOptions()) { _ in }), width: 300, height: 100)
      defer { screen.close() }
      let menu = try screen.openMenu(#require(screen.popUps.first))
      #expect(menu.item(named: SessionShowScope.shared.title) != nil)
    }

    @Test("Bulk delete offers to clean up branches when any selected session has one")
    func bulkDeleteBranches() throws {
      var state = SidebarFixture.state
      state.rowInfo = ["beta": SessionRowInfo(branch: "feature")]
      let spy = SidebarSpy(state)
      var actions = spy.actions
      actions.sessions.deleteWithBranch = { spy.calls.append("delete \($0.id) branch \($1)") }
      let screen = sidebar(spy, actions: actions)
      defer { screen.close() }
      try screen.click(try screen.plainButtons(inRow: 9)[1])
      try screen.clickRow(SidebarFixture.betaRow)
      let delete = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: delete.midX, y: delete.midY))
      screen.settle(0.2)
      #expect(
        try screen.shows(
          "Optionally delete the local git branches of these worktree sessions. This is irreversible."
        ))
      #expect(try screen.shows("feature"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(spy.calls == ["delete beta branch false"])
    }

    @Test("A real double click on a row starts renaming it")
    func doubleClickRenames() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = sidebar(spy)
      defer { screen.close() }
      let point = try screen.center(ofRow: SidebarFixture.betaRow)
      try screen.click(point, clickCount: 1)
      try screen.click(point, clickCount: 2)
      screen.settle(0.2)
      let field = try #require(screen.firstTextField)
      #expect(field.stringValue == "Beta")
      try screen.click(field)
      try screen.type(" two")
      try screen.press(keyCode: 36, characters: "\r")
      #expect(spy.calls.contains { $0.hasPrefix("rename beta Beta") })
    }

    @Test("A row outside selection mode has no check mark, and hides its hover buttons at rest")
    func rowDefaults() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let row = SessionRow(
        session: SidebarFixture.beta, info: SessionRowInfo(), isUnread: false, attention: 0,
        details: [], now: Date(timeIntervalSince1970: 0),
        menu: SessionRowMenu(
          session: SidebarFixture.beta, isUnread: false, isShared: false, pinLimitReached: false,
          projects: [], actions: spy.sessionActions, rename: {}, confirmDelete: {},
          confirmLeave: {},
          confirmStop: {}))
      let screen = OffscreenWindow(
        AnyView(row.frame(width: 280, height: 32)), width: 280, height: 32)
      defer { screen.close() }
      #expect(try screen.shows("Beta"))
      #expect(screen.plainButtons.isEmpty)
    }

    @Test("The sidebar shows Undo after an archive")
    func undoInSidebar() throws {
      var state = SidebarFixture.state
      state.undo = UndoBanner(id: "u", kind: .archived(count: 2))
      let spy = SidebarSpy(state)
      let screen = sidebar(spy)
      defer { screen.close() }
      let undo = UndoBanner(id: "u", kind: .archived(count: 2))
      #expect(try screen.shows(undo.message))
    }
  }

  @Suite("Session list: one row's edges", .serialized)
  @MainActor
  struct SessionListRowEdgeTests {
    @Test("VoiceOver's row actions pin, mark, archive and rename")
    func voiceOverActions() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      var renames = 0
      let menu = SessionRowMenu(
        session: SidebarFixture.beta, isUnread: true, isShared: false, pinLimitReached: false,
        projects: [], actions: spy.sessionActions, rename: { renames += 1 }, confirmDelete: {},
        confirmLeave: {}, confirmStop: {})
      let screen = OffscreenWindow(
        AnyView(VStack { menu.accessibilityItems }), width: 300, height: 200)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 4)
      for index in 0..<4 { try screen.clickControl(at: index) }
      #expect(spy.calls == ["pin beta true", "unread beta false", "archive beta true"])
      #expect(renames == 1)
    }

    @MainActor
    @Observable
    fileprivate final class EditState {
      var isEditing = false
    }

    private struct EditingRow: View {
      let state: EditState
      let spy: SidebarSpy

      var body: some View {
        SessionRow(
          session: SidebarFixture.beta, info: SessionRowInfo(), isUnread: false, attention: 0,
          details: [], now: Date(timeIntervalSince1970: 0),
          menu: SessionRowMenu(
            session: SidebarFixture.beta, isUnread: false, isShared: false, pinLimitReached: false,
            projects: [], actions: spy.sessionActions, rename: {}, confirmDelete: {},
            confirmLeave: {}, confirmStop: {}),
          inlineRename: state.isEditing
            ? InlineRename(text: .constant("Beta"), commit: {}, cancel: {}) : nil)
      }
    }

    @Test("An edit that ends right after it starts leaves nothing waiting to take the focus")
    func quickEndOfEdit() throws {
      let state = EditState()
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(
        AnyView(EditingRow(state: state, spy: spy).frame(width: 280, height: 32)), width: 280,
        height: 32)
      defer { screen.close() }
      // Started and ended inside the delay before the field takes focus.
      state.isEditing = true
      screen.settle(0.01)
      #expect(screen.firstTextField != nil)
      state.isEditing = false
      screen.settle(0.15)
      #expect(screen.firstTextField == nil)
    }

    @Test("The selected row has a fill of its own, outlined under Increase Contrast")
    func selectionBackground() throws {
      let plain = try RenderSupport.picture(
        SidebarSelectionBackground(isSelected: true), width: 200, height: 40)
      let unselected = try RenderSupport.picture(
        SidebarSelectionBackground(isSelected: false), width: 200, height: 40)
      #expect(plain != unselected)
      let outlined = try RenderSupport.picture(
        SidebarSelectionBackground(isSelected: true).environment(
          \._colorSchemeContrast, .increased),
        width: 200, height: 40)
      #expect(outlined != plain)
    }

    @Test("The header with one child just places it")
    func headerLayoutSingleChild() throws {
      let screen = OffscreenWindow(
        AnyView(SidebarHeaderLayout(spacing: 4) { Text("only child") }), width: 300, height: 60)
      defer { screen.close() }
      #expect(try screen.shows("only child"))
    }
  }
#endif
