#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// One window's Settings page, as its window keeps it.
  @MainActor
  private final class PageState {
    var isShown = false
    var page: WindowSettingsPage {
      WindowSettingsPage(isShown: { self.isShown }, setShown: { self.isShown = $0 })
    }
  }

  /// A registry and router with windows that record what the router does to them.
  @MainActor
  private final class SettingsHarness {
    let registry = ServerWindowRegistry { _ in }
    let router: DesktopRouter
    var opened: [ServerWindowID] = []
    var windowRequests = 0

    init() {
      router = DesktopRouter(registry: registry, reportIssue: { _ in })
      router.requestWindow = { [weak self] in self?.windowRequests += 1 }
      router.attachWindowOpener { [weak self] in self?.opened.append($0) }
    }

    /// Opens a window on `server` and registers its Settings page.
    func window(_ server: String) throws -> (id: ServerWindowID, state: PageState) {
      let id = ServerWindowID.newWindow(serverURL: try url(server))
      let state = PageState()
      registry.update(id, isReady: true, viewedSessionID: nil, unreadCount: 0)
      registry.setSettingsPage(for: id.instance, state.page)
      return (id, state)
    }
  }

  /// Settings in the front window, from Omnigent > Settings and the menu bar.
  @MainActor
  @Suite("Settings in the front window", .serialized)
  struct WindowSettingsPageTests {
    init() { DesktopSideEffects.reset() }

    @Test("Command-comma shows the front window's Settings, and again goes back")
    func toggles() throws {
      let harness = SettingsHarness()
      let (id, state) = try harness.window("https://a.test")
      harness.router.showSettings(toggling: true)
      #expect(state.isShown)
      #expect(harness.opened == [id], "the window comes forward")
      harness.router.showSettings(toggling: true)
      #expect(!state.isShown)
      #expect(harness.windowRequests == 0)
    }

    @Test("the menu bar's Settings shows the page and never hides it")
    func showsWithoutToggling() throws {
      let harness = SettingsHarness()
      let (_, state) = try harness.window("https://a.test")
      harness.router.showSettings()
      harness.router.showSettings()
      #expect(state.isShown)
    }

    @Test("the front window is the key one, then the one that was key last")
    func frontWindow() throws {
      let harness = SettingsHarness()
      let (first, firstState) = try harness.window("https://a.test")
      let (second, secondState) = try harness.window("https://b.test")
      // Neither was key yet: the newest window is in front.
      harness.router.showSettings()
      #expect(secondState.isShown && !firstState.isShown)

      harness.registry.setKey(first.instance, isKey: true)
      harness.router.showSettings()
      #expect(firstState.isShown)

      // Another kind of window is key now (the logs): the last key server window still counts.
      harness.registry.setKey(first.instance, isKey: false)
      firstState.isShown = false
      harness.router.showSettings()
      #expect(firstState.isShown)
      #expect(harness.opened.last == first)

      // A closed window is forgotten.
      harness.registry.remove(first.instance)
      secondState.isShown = false
      harness.router.showSettings()
      #expect(secondState.isShown)
      #expect(harness.opened.last == second)
    }

    @Test("with no window, Settings opens one and shows there")
    func opensAWindow() throws {
      let harness = SettingsHarness()
      harness.router.showSettings(toggling: true)
      #expect(harness.windowRequests == 1)
      #expect(harness.registry.settingsPages.awaitsWindow)

      let (_, state) = try harness.window("https://a.test")
      #expect(state.isShown, "the window that opened shows Settings")
      #expect(!harness.registry.settingsPages.awaitsWindow)
      let (_, later) = try harness.window("https://b.test")
      #expect(!later.isShown, "only the first window after the request")
    }

    @Test("a window registers its page when it appears")
    func modifierRegisters() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let id = ServerWindowID.newWindow(serverURL: try url("https://a.test"))
      let state = PageState()
      let screen = OffscreenWindow(
        Text(verbatim: "Window")
          .serverWindowSettings(id.instance, desktop: fixture.desktop, page: state.page),
        width: 200, height: 100)
      defer { screen.close() }
      fixture.desktop.router.requestWindow = {}
      fixture.desktop.router.showSettings(toggling: true)
      #expect(state.isShown)
    }

    @Test("Omnigent > Settings is Command-comma and runs the app's action")
    func menuItem() throws {
      var shown = 0
      let screen = OffscreenWindow(
        MenuHost { SettingsMenuItem(showSettings: { shown += 1 }) }, width: 200, height: 80)
      defer { screen.close() }
      let frame = try #require(screen.controlFrames.first)
      let menu = try screen.openMenu(CGPoint(x: frame.midX, y: frame.midY))
      let item = try #require(menu.items.first { $0.title == "Settings\u{2026}" })
      #expect(item.keyEquivalent == ",")
      #expect(item.keyEquivalentModifierMask == .command)
      try screen.choose("Settings\u{2026}", in: menu)
      #expect(shown == 1)
    }

    @Test("the menus replace the Settings item only for an app that shows Settings itself")
    func commands() throws {
      let own = OmnigentDesktopCommands(
        actions: DesktopCommandActions(defaultServerURL: { nil }, showSettings: {}))
      // The group is there or not; its item is built when the menu opens.
      typealias SettingsGroup = CommandGroup<SettingsMenuItem>
      #expect(firstValue(of: SettingsGroup.self, in: own.body) != nil)
      let scene = OmnigentDesktopCommands(actions: DesktopCommandActions(defaultServerURL: { nil }))
      #expect(firstValue(of: SettingsGroup.self, in: scene.body) == nil)
    }

    @Test("the menu bar's Settings shows the app's own Settings when it has one")
    func menuBar() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var shown = 0
      let screen = OffscreenWindow(
        OmnigentMenuBarContent(
          desktop: fixture.desktop, sessions: nil, showSettings: { shown += 1 }),
        width: 340, height: 720)
      defer { screen.close() }
      // The panel's last rows: Quit, then Settings above it.
      let rows = screen.controlFrames
      try screen.click(rows[rows.count - 2])
      #expect(shown == 1)
      #expect(SystemSideEffects.record.activationCount == 1)
    }
  }
#endif
