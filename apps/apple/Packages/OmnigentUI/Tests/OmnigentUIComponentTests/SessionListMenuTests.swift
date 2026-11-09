#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: a session row's context menu", .serialized)
  @MainActor
  struct SessionListMenuTests {
    private func sidebar(_ state: SidebarViewState = SidebarFixture.state) -> (
      SidebarSpy, OffscreenWindow<SidebarHarness>
    ) {
      let spy = SidebarSpy(state)
      return (spy, OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700))
    }

    private func choose(
      _ title: String, row: Int, _ screen: OffscreenWindow<SidebarHarness>
    ) throws {
      try screen.choose(title, in: try #require(try screen.menu(ofRow: row)))
    }

    @Test("the menu lists the web's items in order")
    func order() throws {
      let (_, screen) = sidebar()
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      #expect(
        menu.titles == [
          "Pin", "Share", "Fork", "Rename\u{2026}", "Mark as unread", "Add to project", "Archive",
          "Delete\u{2026}", "Open in New Window", "Open in Split View", "Copy Link",
          "Copy Session ID",
        ])
    }

    @Test("Pin, Unpin, Archive, Fork, Share, Mark as unread and the window items reach the host")
    func directActions() throws {
      var state = SidebarFixture.state
      state.list.unreadIds = ["gamma"]
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      try choose("Pin", row: SidebarFixture.betaRow, screen)
      try choose("Unpin", row: SidebarFixture.pinnedRow, screen)
      try choose("Archive", row: SidebarFixture.betaRow, screen)
      try choose("Fork", row: SidebarFixture.betaRow, screen)
      try choose("Share", row: SidebarFixture.betaRow, screen)
      try choose("Mark as unread", row: SidebarFixture.betaRow, screen)
      try choose("Mark as read", row: SidebarFixture.gammaRow, screen)
      try choose("Open in New Window", row: SidebarFixture.betaRow, screen)
      try choose("Open in Split View", row: SidebarFixture.betaRow, screen)
      #expect(
        spy.calls == [
          "pin beta true", "pin pinned false", "archive beta true", "fork beta", "share beta",
          "unread beta true", "unread gamma false", "window beta", "split beta",
        ])
    }

    @Test("Copy Link and Copy Session ID land on the clipboard, not the person's")
    func copies() throws {
      let (_, screen) = sidebar()
      defer { screen.close() }
      try choose("Copy Session ID", row: SidebarFixture.betaRow, screen)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "beta")
      try choose("Copy Link", row: SidebarFixture.betaRow, screen)
      #expect(
        SystemSideEffects.pasteboard.string(forType: .string) == "https://example.test/s/beta")
    }

    @Test("at the pin limit Pin is disabled, and a pinned row can still unpin")
    func pinLimit() throws {
      var state = SidebarFixture.state
      state.pinLimit = 1
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      #expect(menu.item(named: "Pin")?.isEnabled == false)
      let pinnedMenu = try #require(try screen.menu(ofRow: SidebarFixture.pinnedRow))
      #expect(pinnedMenu.item(named: "Unpin")?.isEnabled == true)
      try screen.choose("Unpin", in: pinnedMenu)
      #expect(spy.calls == ["pin pinned false"])
    }

    @Test("Rename asks with the current title; confirming keeps it trimmed")
    func rename() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      try choose("Rename\u{2026}", row: SidebarFixture.betaRow, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Rename Session"])
      #expect(spy.calls == ["rename beta Beta"])
    }

    @Test("Delete asks first; Cancel deletes nothing")
    func deleteConfirmation() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try choose("Delete\u{2026}", row: SidebarFixture.betaRow, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Delete this session?"])
      #expect(spy.calls.isEmpty)
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try choose("Delete\u{2026}", row: SidebarFixture.betaRow, screen)
      #expect(spy.calls == ["delete beta"])
    }

    @Test("Stop asks first and only shows for a session that can stop")
    func stop() throws {
      var state = SidebarFixture.state
      state.list.sessions[1].canStop = true
      var info = SessionRowInfo()
      info.runsOnHost = true
      state.rowInfo["beta"] = info
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      #expect(try screen.menu(ofRow: SidebarFixture.gammaRow)?.item(named: "Stop session") == nil)
      try choose("Stop session", row: SidebarFixture.betaRow, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Stop session?"])
      #expect(spy.calls == ["stop beta"])
    }

    @Test("a shared session offers Leave, not Delete, Share, Move or Rename in place")
    func sharedSession() throws {
      var state = SidebarFixture.state
      state.projects = [SessionProject(id: "p", name: "Alpha", sessionIds: [])]
      state.rowInfo["beta"] = SessionRowInfo(isShared: true)
      state.list.sessions[1].canStop = true
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      // Rows after Projects' one folder, then Shared with beta, then Sessions with gamma.
      let row = 10
      let menu = try #require(try screen.menu(ofRow: row))
      #expect(menu.item(named: "Delete\u{2026}") == nil)
      #expect(menu.item(named: "Share") == nil)
      #expect(menu.item(named: "Add to project") == nil)
      #expect(menu.item(named: "Stop session")?.isEnabled == false)
      try choose("Leave session\u{2026}", row: row, screen)
      #expect(SystemSideEffects.record.alertMessages == ["Leave this session?"])
      #expect(spy.calls == ["leave beta"])
    }

    @Test("Fork and Share stay visible, disabled, when they can't run")
    func unavailableReasons() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      var actions = spy.actions
      actions.sessions.forkUnavailableReason = { _ in "Nothing to fork yet" }
      actions.sessions.shareUnavailableReason = "Sharing is off on this server"
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy, actions: actions), width: 300, height: 700)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      #expect(menu.items.first { $0.title.hasPrefix("Fork") }?.isEnabled == false)
      #expect(menu.items.first { $0.title.hasPrefix("Share") }?.isEnabled == false)
    }

    @Test("an archived row offers Unarchive and neither Pin nor Split View")
    func archivedRow() throws {
      var state = SidebarViewState(
        list: SessionListViewState(sessions: [
          SessionSummary(id: "old", title: "Old", isArchived: true)
        ]))
      state.display.show = .archived
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      // Projects header, "No projects", Sessions header, the row.
      let row = 8
      let menu = try #require(try screen.menu(ofRow: row))
      #expect(menu.item(named: "Pin") == nil)
      #expect(menu.item(named: "Open in Split View") == nil)
      try screen.choose("Unarchive", in: menu)
      #expect(spy.calls == ["archive old false"])
    }

    @Test("Move: filing, the current folder disabled, Remove from project, and the folder opens")
    func moveToProject() throws {
      var state = SidebarFixture.state
      state.projects = [
        SessionProject(id: "p1", name: "Alpha", sessionIds: ["gamma"]),
        SessionProject(id: "p2", name: "Delta", sessionIds: []),
      ]
      state.list.sessions = [SidebarFixture.beta, SidebarFixture.gamma]
      let (spy, screen) = sidebar(state)
      defer { screen.close() }
      // 5 Projects, 6 Alpha, 7 Delta, 8 Sessions, 9 beta.
      let loose = try #require(try screen.menu(ofRow: 9))
      #expect(loose.item(named: "Add to project") != nil)
      #expect(loose.item(named: "Remove from project") == nil)
      try screen.choose("Delta", in: loose)
      // Moving opens the target so the session doesn't hide in a collapsed folder, and an open
      // folder reads its first page.
      #expect(spy.calls == ["move beta p2", "load project p2"])
      #expect(
        UserDefaults.standard.string(forKey: SidebarNavigationOrder.expandedProjectsKey) == "p2")
    }
  }
#endif
