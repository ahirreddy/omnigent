#if os(macOS)
  import AppKit
  import OmnigentAuthUI
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: the bars under the list", .serialized)
  @MainActor
  struct SessionListBarTests {
    private let one = SessionSummary(id: "one", title: "One")
    private let two = SessionSummary(id: "two", title: "Two")
    private let done = SessionSummary(id: "done", title: "Done", isArchived: true)
    private let project = SessionProject(id: "p", name: "Work", sessionIds: [])

    private func bar(
      _ selected: [SessionSummary], spy: SidebarSpy, actions: SidebarActions? = nil
    ) -> some View {
      BulkActionBar(
        selected: selected, state: spy.state, actions: actions ?? spy.actions,
        exit: { spy.calls.append("exit") }, clear: { spy.calls.append("clear") },
        confirmDelete: { spy.calls.append("confirm \($0.map(\.id).joined(separator: ","))") }
      )
      .frame(width: 320, height: 60)
    }

    @Test("Exit selection, and a session count")
    func exit() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(bar([one, two], spy: spy), width: 320, height: 60)
      defer { screen.close() }
      // Exit, Mark as unread, Archive, Delete.
      #expect(screen.controlFrames.count == 4)
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["exit"])
    }

    @Test("Mark as read clears the unread ones, then leaves selection")
    func markRead() throws {
      var state = SidebarFixture.state
      state.list.unreadIds = ["one"]
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(bar([one, two], spy: spy), width: 320, height: 60)
      defer { screen.close() }
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["unread one false", "exit"])
    }

    @Test("Mark as unread marks everything selected, then leaves selection")
    func markUnread() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(bar([one, two], spy: spy), width: 320, height: 60)
      defer { screen.close() }
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["unread one true", "unread two true", "exit"])
    }

    @Test("Archive and Unarchive only show for a selection all one way")
    func archive() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let active = OffscreenWindow(bar([one, two], spy: spy), width: 320, height: 60)
      defer { active.close() }
      try active.clickControl(at: 2)
      #expect(spy.calls == ["archive many one,two true", "clear"])

      spy.calls = []
      let archived = OffscreenWindow(bar([done], spy: spy), width: 320, height: 60)
      defer { archived.close() }
      try archived.clickControl(at: 2)
      #expect(spy.calls == ["archive many done false", "clear"])

      let mixed = OffscreenWindow(bar([one, done], spy: spy), width: 320, height: 60)
      defer { mixed.close() }
      // Exit, Mark as unread, Delete: neither way would suit all of them.
      #expect(mixed.controlFrames.count == 3)
      try mixed.clickControl(at: 2)
      #expect(spy.calls.last == "confirm one,done")
    }

    @Test("Delete names how many when some selected sessions aren't yours")
    func deleteOwnedOnly() throws {
      var state = SidebarFixture.state
      state.rowInfo = ["two": SessionRowInfo(isShared: true)]
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(bar([one, two], spy: spy), width: 320, height: 60)
      defer { screen.close() }
      try screen.clickControl(at: 3)
      #expect(spy.calls == ["confirm one"])

      let everyone = OffscreenWindow(bar([two], spy: spy), width: 320, height: 60)
      defer { everyone.close() }
      // Read state is per viewer, so it still applies to a session someone shared; nothing else.
      #expect(everyone.controlFrames.count == 2)
      try everyone.clickControl(at: 1)
      #expect(spy.calls.suffix(2) == ["unread two true", "exit"])
    }

    @Test("Move to project moves what's yours and leaves selection")
    func move() throws {
      var state = SidebarFixture.state
      state.projects = [project]
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(bar([one, two], spy: spy), width: 320, height: 60)
      defer { screen.close() }
      #expect(screen.popUps.count == 1)
      let menu = try screen.openMenu(try #require(screen.popUps.first))
      #expect(menu.titles == ["Work", "Remove from project"])
      try screen.choose("Work", in: menu)
      #expect(spy.calls == ["move one p", "move two p", "exit"])
      spy.calls = []
      try screen.choose("Remove from project", in: menu)
      #expect(spy.calls == ["move one none", "move two none", "exit"])
    }

    @Test("no actions, no buttons beyond Exit")
    func noActions() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let none = SidebarActions(sessions: SessionListActions())
      let screen = OffscreenWindow(bar([], spy: spy, actions: none), width: 320, height: 60)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 1)
    }

    @Test("a shift click checks the range from the last row; a plain click toggles one")
    func selectionRange() {
      var bulk = SidebarBulkSelection()
      let order = ["a", "b", "c", "d"]
      bulk.begin()
      #expect(bulk.isActive)
      bulk.toggle("b", extending: false, order: order)
      bulk.toggle("d", extending: true, order: order)
      #expect(bulk.ids == ["b", "c", "d"])
      bulk.toggle("a", extending: true, order: order)
      #expect(bulk.ids == ["a", "b", "c", "d"])
      bulk.toggle("c", extending: false, order: order)
      #expect(bulk.ids == ["a", "b", "d"])
      // A row no longer listed can't anchor a range, so it just toggles.
      bulk.toggle("gone", extending: true, order: order)
      #expect(bulk.ids.contains("gone"))
      bulk.clear()
      #expect(bulk.ids.isEmpty && bulk.isActive)
      bulk.toggle("a", extending: true, order: order)
      #expect(bulk.ids == ["a"])
      bulk.end()
      #expect(!bulk.isActive && bulk.ids.isEmpty)
    }

    private func undo(_ kind: UndoBanner.Kind, note: String? = nil, spy: SidebarSpy) -> some View {
      UndoBar(banner: UndoBanner(id: "u", kind: kind, note: note), actions: spy.actions)
        .frame(width: 320, height: 90)
    }

    @Test("the undo bar offers Undo, Dismiss, and View archived after an archive")
    func undoBar() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(
        undo(.archived(count: 1), note: "Keeps the worktree", spy: spy), width: 320, height: 90)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      try screen.clickControl(at: 1)
      try screen.clickControl(at: 2)
      #expect(spy.calls == ["view archived", "undo u", "dismiss undo"])
      spy.calls = []
      // Undo keeps the system's shortcut while the bar is up.
      try screen.press(keyCode: 6, characters: "z", modifiers: .command)
      #expect(spy.calls == ["undo u"])
    }

    @Test("View archived only follows an archive, and the bar shows only what it can do")
    func undoBarVariants() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = OffscreenWindow(undo(.pinned, spy: spy), width: 320, height: 90)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2)
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["undo u"])
      let none = OffscreenWindow(
        UndoBar(
          banner: UndoBanner(id: "u", kind: .archived(count: 2)),
          actions: SidebarActions(sessions: SessionListActions())),
        width: 320, height: 90)
      defer { none.close() }
      #expect(none.controlFrames.isEmpty)
    }

    private func sidebar(account: SignedInAccount?, spy: SidebarSpy) -> OffscreenWindow<AnyView> {
      spy.state.account = account
      return OffscreenWindow(AnyView(SidebarHarness(spy: spy)), width: 300, height: 600)
    }

    /// How far the list's rows stay clear of the sidebar's foot.
    private func listBottomInset(_ screen: OffscreenWindow<AnyView>) throws -> CGFloat {
      try #require(screen.list?.enclosingScrollView).contentInsets.bottom
    }

    @Test("the account sits at the sidebar's foot across its width, and its menu signs out")
    func accountFooter() throws {
      let account = SignedInAccount(
        baseUrl: "https://omnigent.example.com", serverName: "Example Agents", userId: "ada",
        accountId: "a1", mode: .oidc)
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = sidebar(account: account, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("ada"))
      #expect(try screen.shows("Example Agents"))
      let footer = try #require(screen.controlFrames.last)
      #expect(footer.maxY > 580 && footer.minY > 520, "pinned to the foot: \(footer)")
      #expect(footer.width >= 280, "as wide as the sidebar, less its margins: \(footer)")
      #expect(try listBottomInset(screen) >= footer.height, "the rows end above it")
      let menu = try screen.openMenu(CGPoint(x: footer.midX, y: footer.midY))
      #expect(menu.items.map(\.title).contains("Signed in as ada"))
      try screen.choose("Sign Out", in: menu)
      #expect(spy.calls == ["sign out"])
    }

    @Test("with no account the footer takes no room: the list reaches the sidebar's foot")
    func noAccountFooter() throws {
      let screen = sidebar(account: nil, spy: SidebarSpy(SidebarFixture.state))
      defer { screen.close() }
      #expect(try listBottomInset(screen) == 0)
    }
  }
#endif
