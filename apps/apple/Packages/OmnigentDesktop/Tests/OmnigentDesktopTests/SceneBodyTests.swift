#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import Synchronization
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// Finds a value inside a scene, which SwiftUI otherwise only reads while it runs an app.
  /// Reference types aren't entered: they lead out of the scene, and can form cycles.
  func firstValue<Wanted>(of _: Wanted.Type, in root: Any, labeled label: String? = nil) -> Wanted?
  {
    let mirror = Mirror(reflecting: root)
    for child in mirror.children {
      if let wanted = child.value as? Wanted, label == nil || child.label == label { return wanted }
      guard Mirror(reflecting: child.value).displayStyle != .class else { continue }
      if let found = firstValue(of: Wanted.self, in: child.value, labeled: label) { return found }
    }
    return nil
  }

  /// The scenes and menus the app declares, read without running them as an app.
  @MainActor
  @Suite("Scene declarations", .serialized)
  struct SceneBodyTests {
    init() { DesktopSideEffects.reset() }

    private typealias WindowRoot = PresentedWindowContent<ServerWindowID, WindowMinimumSize<Text>>

    @Test("a system-opened server window starts on the default server, at the minimum size")
    func serverWindow() throws {
      let server = try url("https://team.test")
      let scene = ServerWindowScene(
        "Omnigent", defaultServerURL: { server },
        content: { window in Text(window.wrappedValue.serverURL?.host() ?? "no server") })
      let body = scene.body
      let type = String(describing: Swift.type(of: body))
      #expect(type.contains("UnifiedWindowToolbarStyle"))
      #expect(type.contains("WindowMinimumSize<Text>"))
      let makeRoot = try #require(
        firstValue(of: (() -> WindowRoot).self, in: body, labeled: "lazy"))
      let screen = OffscreenWindow(makeRoot(), width: 800, height: 700)
      defer { screen.close() }
      #expect(try screen.shownText().joined().contains("team.test"))
    }

    @Test("Server Logs shows the manager's logs and hands the router its window opener")
    func logsWindow() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let scene = LocalServerLogsWindow(
        manager: fixture.manager, router: fixture.desktop.router)
      #expect(LocalServerLogsWindow.id == "omnigent.local-server.logs")
      let opener = try #require(firstValue(of: RouterWindowOpener.self, in: scene.body))
      #expect(opener.router === fixture.desktop.router)
      #expect(firstValue(of: LocalServerLogsView.self, in: scene.body) != nil)
    }

    @Test("the menu bar icon starts from the server and the sessions needing the user")
    func menuBarExtra() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let sessions = FakeMenuBarSessionSource(unreadCount: 3)
      let scene = OmnigentMenuBarExtra(desktop: fixture.desktop, sessions: sessions)
      let label = try #require(firstValue(of: OmnigentMenuBarLabel.self, in: scene.body))
      #expect(label.state == MenuBarLabelState(isServerRunning: false, unreadCount: 3))
      #expect(firstValue(of: OmnigentMenuBarContent.self, in: scene.body) != nil)

      let quiet = OmnigentMenuBarExtra(desktop: fixture.desktop)
      let quietLabel = try #require(firstValue(of: OmnigentMenuBarLabel.self, in: quiet.body))
      #expect(quietLabel.state.unreadCount == 0)
    }

    @Test("the status item's constant write-backs don't disturb the preference's observers")
    func menuBarVisibility() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let preferences = fixture.desktop.localServerPreferences
      let isInserted = OmnigentMenuBarExtra.isInserted(preferences)
      #expect(isInserted.wrappedValue == preferences.showsMenuBarExtra)

      let changes = Mutex(0)
      withObservationTracking {
        _ = preferences.showsMenuBarExtra
      } onChange: {
        changes.withLock { $0 += 1 }
      }
      isInserted.wrappedValue = preferences.showsMenuBarExtra
      #expect(changes.withLock { $0 } == 0)
      let other = !preferences.showsMenuBarExtra
      isInserted.wrappedValue = other
      #expect(changes.withLock { $0 } == 1)
      #expect(preferences.showsMenuBarExtra == other)
    }

    @Test("the menu bar lists every menu, with the local server in Server")
    func commands() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let commands = OmnigentDesktopCommands(
        actions: DesktopCommandActions(
          defaultServerURL: { nil }, checkForUpdates: {}, localServer: fixture.manager))
      let body = commands.body
      let type = String(describing: Swift.type(of: body))
      let menus = [
        "NewWindowMenuItems", "FindMenu", "ViewMenuItems", "HelpMenuItems", "Button<Text>",
      ]
      for menu in menus { #expect(type.contains(menu)) }
      let server = try #require(firstValue(of: ServerMenuItems.self, in: body))
      #expect(server.localServer === fixture.manager)
      #expect(server.window == nil)
    }
  }
#endif
