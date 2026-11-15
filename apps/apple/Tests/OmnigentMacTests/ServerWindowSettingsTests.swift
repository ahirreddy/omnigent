import AppKit
import OmnigentAppUI
import OmnigentDesktop
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

#if DEBUG
  /// Settings as a page of a real server window, on the core's offline demo server.
  @MainActor
  @Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
  struct ServerWindowSettingsTests {
    private typealias Host = ServerWindowRootTests.Host
    private typealias WindowBinding = ServerWindowRootTests.WindowBinding

    private let demoURL = URL(string: ServerSession.demoServerURL)
    private let notesRow = "#session-row-demo-notes"

    /// A window on the demo server, signed in, with its sessions listed.
    private func openWindow(_ scratch: TestScratch) async throws -> (
      OffscreenWindow<Host>, UUID
    ) {
      ChaosTargets.buildAccessibilityTree()
      let binding = WindowBinding(ServerWindowID(serverURL: demoURL))
      let screen = OffscreenWindow(
        Host(binding: binding, services: scratch.services), width: 1200, height: 800)
      let registry = scratch.desktop.registry
      let instance = binding.id.instance
      #expect(try await screen.waitFor { registry.entry(instance)?.isReady == true })
      #expect(try await screen.waitFor { screen.hasControl(notesRow) }, "\(screen.controlNames)")
      // The window attached SwiftUI's own opener when it appeared; a test brings none forward.
      scratch.desktop.router.attachWindowOpener { _ in }
      return (screen, instance)
    }

    private func demoScratch() throws -> TestScratch {
      try TestScratch(launchArguments: ["-OmnigentDemo"])
    }

    /// Command-comma shows Settings over the whole window, and again goes back to it.
    @Test func commandCommaTogglesSettingsInTheWindow() async throws {
      let scratch = try demoScratch()
      defer { scratch.remove() }
      let (screen, _) = try await openWindow(scratch)
      defer { screen.close() }
      let router = scratch.desktop.router

      router.showSettings(toggling: true)
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })
      #expect(screen.hasControl("#settings.submit-with-command-return"), "General shows first")
      #expect(!screen.hasControl(notesRow), "the session sidebar is under the page")
      #expect(!screen.hasControl("#sidebar-settings"))

      router.showSettings(toggling: true)
      #expect(try await screen.waitFor { screen.hasControl(notesRow) })
      #expect(!screen.hasControl("#settings-back"))
    }

    /// The sidebar's gear opens the page; Back returns to the session that was showing.
    @Test func theGearOpensSettingsAndBackReturnsToTheSession() async throws {
      let scratch = try demoScratch()
      defer { scratch.remove() }
      let (screen, instance) = try await openWindow(scratch)
      defer { screen.close() }
      let registry = scratch.desktop.registry
      registry.deliver(.conversation(sessionID: "demo-notes"), to: instance)
      #expect(
        try await screen.waitFor { registry.entry(instance)?.viewedSessionID == "demo-notes" })

      try screen.clickControl(named: "#sidebar-settings")
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })
      #expect(
        try await screen.waitFor { registry.entry(instance)?.viewedSessionID == nil },
        "nobody is viewing the chat under Settings")
      // Another category, by a settings link: Back must still return to the session.
      registry.deliver(.settings(section: "terminal"), to: instance)
      #expect(
        try await screen.waitFor { screen.hasControl("#settings.terminal-font-family") },
        "\(screen.controlNames)")

      try screen.clickControl(named: "#settings-back")
      #expect(try await screen.waitFor { screen.hasControl(notesRow) })
      #expect(
        try await screen.waitFor { registry.entry(instance)?.viewedSessionID == "demo-notes" })
    }

    /// Escape leaves Settings, as Back does.
    @Test func escapeLeavesSettings() async throws {
      let scratch = try demoScratch()
      defer { scratch.remove() }
      let (screen, _) = try await openWindow(scratch)
      defer { screen.close() }
      scratch.desktop.router.showSettings()
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })
      let escape = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
          context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
          isARepeat: false, keyCode: 53))
      #expect(screen.window.performKeyEquivalent(with: escape))
      #expect(try await screen.waitFor { screen.hasControl(notesRow) })
    }

    /// A settings link lands on its category: a tab, or a server's pane on the Servers category.
    @Test func aSettingsLinkLandsOnItsCategory() async throws {
      let scratch = try demoScratch()
      defer { scratch.remove() }
      let (screen, instance) = try await openWindow(scratch)
      defer { screen.close() }
      let registry = scratch.desktop.registry

      registry.deliver(.settings(section: "appearance"), to: instance)
      #expect(try await screen.waitFor { screen.hasControl("#settings.terminal-theme") })

      registry.deliver(.settings(section: "mcp"), to: instance)
      #expect(
        try await screen.waitFor { screen.hasControl("#server-settings-picker") },
        "\(screen.controlNames)")
      #expect(!screen.hasControl("#settings.terminal-theme"))
    }

    /// A link to a conversation, followed while Settings shows, shows the conversation.
    @Test func aLinkToAConversationLeavesSettings() async throws {
      let scratch = try demoScratch()
      defer { scratch.remove() }
      let (screen, instance) = try await openWindow(scratch)
      defer { screen.close() }
      let registry = scratch.desktop.registry
      scratch.desktop.router.showSettings()
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })

      registry.deliver(.conversation(sessionID: "demo-design"), to: instance)
      #expect(try await screen.waitFor { screen.hasControl(notesRow) })
      #expect(
        try await screen.waitFor { registry.entry(instance)?.viewedSessionID == "demo-design" })
      #expect(!screen.hasControl("#settings-back"))
    }

    /// With no window open, Settings asks for one, and that window opens on Settings.
    @Test func settingsWithNoWindowOpensOneOnSettings() async throws {
      let scratch = try demoScratch()
      defer { scratch.remove() }
      var requests = 0
      scratch.desktop.router.requestWindow = { requests += 1 }
      scratch.desktop.router.showSettings(toggling: true)
      #expect(requests == 1)

      ChaosTargets.buildAccessibilityTree()
      let binding = WindowBinding(ServerWindowID(serverURL: demoURL))
      let screen = OffscreenWindow(
        Host(binding: binding, services: scratch.services), width: 1200, height: 800)
      defer { screen.close() }
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })
    }

    /// Settings shows on the connect screen too, before any server is chosen.
    @Test func settingsShowsWithoutAServer() async throws {
      let scratch = try TestScratch()
      defer { scratch.remove() }
      ChaosTargets.buildAccessibilityTree()
      let binding = WindowBinding(ServerWindowID(serverURL: nil))
      let screen = OffscreenWindow(
        Host(binding: binding, services: scratch.services), width: 1200, height: 800)
      defer { screen.close() }
      let registry = scratch.desktop.registry
      #expect(try await screen.waitFor { registry.entry(binding.id.instance) != nil })
      scratch.desktop.router.attachWindowOpener { _ in }
      scratch.desktop.router.showSettings()
      #expect(try await screen.waitFor { screen.hasControl("#settings-back") })
      #expect(try await screen.waitFor { screen.hasControl("#settings-category-Advanced") })
    }
  }
#endif

/// How a window's Settings page is reached, without a window on screen.
@MainActor
struct SettingsPageWiringTests {
  /// The menus reach a window's page through its navigator.
  @Test func theWindowsPageFollowsItsNavigator() {
    let navigator = SettingsNavigator()
    let page = ServerWindowRoot.windowPage(navigator)
    #expect(!page.isShown())
    page.setShown(true)
    #expect(navigator.isPresented && page.isShown())
    page.setShown(false)
    #expect(!navigator.isPresented)
  }

  /// Only a link to Settings keeps Settings showing.
  @Test func linksElsewhereLeaveSettings() {
    #expect(!ServerWindowRoot.leavesSettings(.settings(section: nil)))
    #expect(ServerWindowRoot.leavesSettings(.home))
    #expect(ServerWindowRoot.leavesSettings(.conversation(sessionID: "demo-notes")))
  }

  /// Omnigent > Settings and the menu bar's Settings both go through the router.
  @Test func theAppsSettingsActionsUseTheFrontWindow() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let navigator = SettingsNavigator()
    let id = ServerWindowID(serverURL: nil)
    scratch.desktop.registry.setSettingsPage(
      for: id.instance, ServerWindowRoot.windowPage(navigator))
    let toggle = OmnigentMacApp.showSettings(desktop: scratch.desktop, toggling: true)
    let show = OmnigentMacApp.showSettings(desktop: scratch.desktop, toggling: false)
    toggle()
    #expect(navigator.isPresented)
    toggle()
    #expect(!navigator.isPresented)
    show()
    show()
    #expect(navigator.isPresented)
  }

  /// A window is built over the launch's services, with the updater where the edition has one.
  @Test func aWindowIsBuiltOverTheLaunchsServices() {
    let delegate = OmnigentMacAppDelegate()
    let binding = ServerWindowRootTests.WindowBinding(ServerWindowID(serverURL: nil))
    let root = OmnigentMacApp.windowRoot(
      Binding(get: { binding.id }, set: { binding.id = $0 }), delegate: delegate)
    #expect(root.services === delegate.services)
    #if OMNIGENT_CHROMIUM
      #expect(root.updater === delegate.updater)
    #endif
  }

  /// A tab becomes a category with the same title, icon, width and pane.
  @Test func aTabIsACategory() {
    let tab = SettingsTabItem("Servers", systemImage: "network", isWide: true) {
      Text(verbatim: "pane")
    }
    let category = AppSettingsView.category(tab)
    #expect(category.id == "Servers" && category.title == "Servers")
    #expect(category.systemImage == "network")
    #expect(category.isWide)
  }
}
