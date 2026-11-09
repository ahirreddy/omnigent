#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// The menus, listed as `CommandGroup` lists them and chosen with their real actions.
  @MainActor
  @Suite("Desktop menus", .serialized)
  struct DesktopCommandsTests {
    init() { DesktopSideEffects.reset() }

    private func window(
      _ server: String = "https://a.test", actions: ServerWindowActions = ServerWindowActions()
    ) throws -> FocusedServerWindow {
      FocusedServerWindow(
        id: ServerWindowID.newWindow(serverURL: try url(server)), actions: actions)
    }

    private func menu<Items: View>(
      of screen: OffscreenWindow<MenuHost<Items>>
    ) throws -> NSMenu {
      let frame = try #require(screen.controlFrames.first)
      return try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func hosted<Items: View>(_ items: Items) -> OffscreenWindow<MenuHost<Items>> {
      OffscreenWindow(MenuHost { items }, width: 200, height: 80)
    }

    private func item(_ menu: NSMenu, _ title: String) throws -> NSMenuItem {
      try #require(menu.items.first { $0.title == title }, "\(title) in \(menu.items)")
    }

    @Test("New Session needs a window, and New Window keeps the key window's server")
    func newItems() throws {
      var created = 0
      var opened: [ServerWindowID] = []
      let actions = ServerWindowActions(newSession: { created += 1 })
      let screen = hosted(
        NewWindowMenuItems(
          window: try window(actions: actions), defaultServerURL: { nil },
          openServerWindow: { opened.append($0) }))
      defer { screen.close() }
      let menu = try menu(of: screen)
      #expect(try item(menu, "New Session").keyEquivalent == "n")
      #expect(try item(menu, "New Window").keyEquivalentModifierMask == [.command, .shift])
      try screen.choose("New Session", in: menu)
      #expect(created == 1)
      try screen.choose("New Window", in: menu)
      #expect(opened.map(\.serverURL) == [try url("https://a.test")])
      try screen.choose("New Window on Different Server\u{2026}", in: menu)
      #expect(opened.last?.serverURL == nil)
      #expect(Set(opened.map(\.instance)).count == 2, "each is its own window")
    }

    @Test("with no window, New Window uses the default server and New Session is off")
    func newItemsWithoutWindow() throws {
      var opened: [ServerWindowID] = []
      let server = try url("https://default.test")
      let screen = hosted(
        NewWindowMenuItems(
          window: nil, defaultServerURL: { server }, openServerWindow: { opened.append($0) }))
      defer { screen.close() }
      let menu = try menu(of: screen)
      #expect(try !item(menu, "New Session").isEnabled)
      try screen.choose("New Window", in: menu)
      #expect(opened.map(\.serverURL) == [server])
    }

    @Test("window items act on the key window and are off when it doesn't offer them")
    func windowItems() throws {
      var calls: [String] = []
      let actions = ServerWindowActions(
        changeServer: { calls.append("change") }, signOut: { calls.append("signOut") })
      let screen = hosted(
        ServerMenuItems(window: try window(actions: actions), localServer: nil, showLogs: {}))
      defer { screen.close() }
      let menu = try menu(of: screen)
      #expect(!menu.items.contains { $0.title == "Start Server on This Mac" })
      try screen.choose("Change Server\u{2026}", in: menu)
      try screen.choose("Sign Out of Server", in: menu)
      #expect(calls == ["change", "signOut"])

      let idle = hosted(ServerMenuItems(window: nil, localServer: nil, showLogs: {}))
      defer { idle.close() }
      let off = try self.menu(of: idle)
      #expect(try !item(off, "Change Server\u{2026}").isEnabled)
      #expect(try !item(off, "Sign Out of Server").isEnabled)
    }

    @Test("an edition that can't run processes lists no local server items")
    func unavailableLocalServer() throws {
      let local = try LocalServerHarness(capability: .unavailable(.appSandbox))
      defer { local.cleanUp() }
      let screen = hosted(ServerMenuItems(window: nil, localServer: local.manager, showLogs: {}))
      defer { screen.close() }
      #expect(try !menu(of: screen).items.contains { $0.title == "Stop Server" })
    }

    @Test("the Server menu starts and stops this Mac's server, and shows its logs")
    func localServerItems() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      var logsShown = 0
      let url = try loopback(6767)
      fixture.local.runner.script(announces(6767))
      fixture.local.probe.answer(url, .ready(nil))
      let screen = hosted(
        ServerMenuItems(
          window: nil, localServer: fixture.manager, showLogs: { logsShown += 1 }))
      defer { screen.close() }
      await flush(screen)
      var menu = try menu(of: screen)
      #expect(try item(menu, "Start Server on This Mac").isEnabled)
      #expect(try !item(menu, "Stop Server").isEnabled)
      #expect(try !item(menu, "Start Host on This Mac\u{2026}").isEnabled, "nothing to host for")
      #expect(try !item(menu, "Stop Host").isEnabled)
      try screen.choose("Show Server Logs", in: menu)
      #expect(logsShown == 1)
      try screen.choose("Start Server on This Mac", in: menu)
      #expect(await settle(screen) { fixture.manager.server.endpoint?.url == url })

      menu = try self.menu(of: screen)
      #expect(try !item(menu, "Start Server on This Mac").isEnabled)
      #expect(try item(menu, "Start Host on This Mac\u{2026}").isEnabled)
      try screen.choose("Stop Server", in: menu)
      #expect(await settle(screen) { fixture.manager.server.endpoint == nil })
    }

    @Test("Start Host hosts this Mac's own server at once, then Stop Host stops it")
    func hostsOwnServerWithoutAsking() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      _ = try await fixture.startServer()
      fixture.local.runner.script { $0.print("\u{2713} Connected as 'mac'.") }
      let screen = hosted(
        ServerMenuItems(window: nil, localServer: fixture.manager, showLogs: {}))
      defer { screen.close() }
      await flush(screen)
      try screen.choose("Start Host on This Mac\u{2026}", in: try menu(of: screen))
      #expect(await settle(screen) { fixture.manager.host.serverURL != nil })
      #expect(SystemSideEffects.record.alertMessages.isEmpty, "no question for this Mac's server")
      try screen.choose("Stop Host", in: try menu(of: screen))
      #expect(await settle(screen) { fixture.manager.host == .stopped })
      await fixture.manager.stopOwnedProcesses()
    }

    @Test(
      "a remote server asks first, and only Start Hosting connects",
      arguments: [
        (NSApplication.ModalResponse.alertFirstButtonReturn, false),
        (NSApplication.ModalResponse.alertSecondButtonReturn, true),
      ])
    func remoteServerAsks(answer: NSApplication.ModalResponse, connects: Bool) async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      SystemSideEffects.answer(alert: answer)
      fixture.local.runner.script { $0.print("\u{2713} Connected as 'mac'.") }
      let screen = hosted(
        ServerMenuItems(
          window: try window("https://team.test"), localServer: fixture.manager, showLogs: {}))
      defer { screen.close() }
      await flush(screen)
      try screen.choose("Start Host on This Mac\u{2026}", in: try menu(of: screen))
      let asked = await settle(screen) { !SystemSideEffects.record.alertMessages.isEmpty }
      #expect(asked)
      #expect(SystemSideEffects.record.alertMessages == ["Allow agents to run on this Mac?"])
      await flush(screen)
      let hosted = fixture.local.runner.launches.contains { $0.arguments.contains("host") }
      #expect(hosted == connects)
      if !connects { #expect(fixture.manager.host == .stopped) }
      await fixture.manager.stopOwnedProcesses()
    }

    @Test("the View menu reconnects and zooms the key window")
    func viewItems() throws {
      var calls: [String] = []
      let zoom = ServerWindowActions.Zoom(
        reset: { calls.append("reset") }, zoomIn: { calls.append("in") },
        zoomOut: { calls.append("out") })
      let actions = ServerWindowActions(reconnect: { calls.append("reconnect") }, zoom: zoom)
      let screen = hosted(ViewMenuItems(window: actions))
      defer { screen.close() }
      let menu = try menu(of: screen)
      #expect(try item(menu, "Actual Size").keyEquivalent == "0")
      #expect(try item(menu, "Zoom In").keyEquivalent == "+")
      #expect(try item(menu, "Zoom Out").keyEquivalent == "-")
      #expect(
        try item(menu, "Reconnect").keyEquivalentModifierMask == [.command, .option, .shift])
      for title in ["Reconnect", "Actual Size", "Zoom In", "Zoom Out"] {
        try screen.choose(title, in: menu)
      }
      #expect(calls == ["reconnect", "reset", "in", "out"])
    }

    @Test("without a window the View menu's items are off")
    func viewItemsOff() throws {
      let screen = hosted(ViewMenuItems(window: nil))
      defer { screen.close() }
      let menu = try menu(of: screen)
      for title in ["Reconnect", "Actual Size", "Zoom In", "Zoom Out"] {
        #expect(try !item(menu, title).isEnabled, "\(title)")
      }
    }

    @Test("Help opens the help page and exports diagnostics; each hides without its action")
    func help() throws {
      var exported = 0
      let helpPage = try url("https://omnigent.ai/docs")
      let actions = DesktopCommandActions(
        defaultServerURL: { nil }, helpURL: helpPage, exportDiagnostics: { exported += 1 })
      let screen = hosted(HelpMenuItems(actions: actions))
      defer { screen.close() }
      let menu = try menu(of: screen)
      try screen.choose("Omnigent Help", in: menu)
      #expect(SystemSideEffects.record.openedURLs == [helpPage])
      try screen.choose("Export Diagnostics\u{2026}", in: menu)
      #expect(exported == 1)
    }

    @Test("Help lists nothing without actions")
    func helpEmpty() throws {
      let screen = hosted(HelpMenuItems(actions: DesktopCommandActions(defaultServerURL: { nil })))
      defer { screen.close() }
      #expect(try menu(of: screen).items.allSatisfy(\.title.isEmpty))
    }

    @Test("Find uses the window's actions when it has them")
    func findActions() throws {
      var calls: [String] = []
      let find = ServerWindowActions.Find(
        show: { calls.append("show") }, next: { calls.append("next") },
        previous: { calls.append("previous") }, useSelection: { calls.append("selection") })
      let screen = OffscreenWindow(FindMenu(find: find), width: 200, height: 80)
      defer { screen.close() }
      let frame = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      let items = menu.items.filter { !$0.title.isEmpty }
      #expect(items.map(\.keyEquivalent) == ["f", "g", "g", "e"])
      for item in items { try screen.choose(item.title, in: menu) }
      #expect(calls == ["show", "next", "previous", "selection"])
    }

    @Test("Use Selection for Find is off when the window's find can't")
    func findWithoutSelection() throws {
      let find = ServerWindowActions.Find(show: {}, next: {}, previous: {})
      let screen = OffscreenWindow(FindMenu(find: find), width: 200, height: 80)
      defer { screen.close() }
      let frame = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      #expect(try !item(menu, "Use Selection for Find").isEnabled)
    }

    @Test("with no window, Find goes up the responder chain for a text view's own find bar")
    func findFallsThrough() throws {
      let recorder = FindActionRecorder()
      let earlier = NSApplication.shared.delegate
      NSApplication.shared.delegate = recorder
      defer { NSApplication.shared.delegate = earlier }
      let screen = OffscreenWindow(FindMenu(find: nil), width: 200, height: 80)
      defer { screen.close() }
      let frame = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      for item in menu.items where !item.title.isEmpty {
        try screen.choose(item.title, in: menu)
      }
      #expect(
        recorder.tagsActedOn == [
          NSTextFinder.Action.showFindInterface.rawValue, NSTextFinder.Action.nextMatch.rawValue,
          NSTextFinder.Action.previousMatch.rawValue, NSTextFinder.Action.setSearchString.rawValue,
        ])
    }
  }

  /// Takes the Find menu's forwarded actions at the end of the responder chain, by sender tag.
  final class FindActionRecorder: NSObject, NSApplicationDelegate {
    var tagsActedOn: [Int] = []

    @objc func performTextFinderAction(_ sender: Any?) {
      if let item = sender as? NSMenuItem { tagsActedOn.append(item.tag) }
    }
  }
#endif
