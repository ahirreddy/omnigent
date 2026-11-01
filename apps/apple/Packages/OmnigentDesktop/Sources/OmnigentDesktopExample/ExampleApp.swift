import AppKit
import OmnigentDesktop
import SwiftUI

// A runnable sanity check for the desktop shell: `swift run OmnigentDesktopExample`.
// `--self-test` prints the menu bar, routes a deep link into a second window, prints the window
// registry and quits. Notifications need an app bundle, so they report as unavailable here.
// `--screenshots=<dir>` starts a real local server in an isolated directory, writes PNGs of the
// Local Server settings, the Server Logs window and the menu bar extra, stops it and quits.

@main
struct OmnigentDesktopExampleApp: App {
  @NSApplicationDelegateAdaptor(ExampleAppDelegate.self) private var appDelegate

  var body: some Scene {
    let desktop = appDelegate.desktop
    ServerWindowScene(
      defaultServerURL: { desktop.preferences.defaultServerURL },
      content: { id in ExampleWindow(id: id, desktop: desktop) }
    )
    .commands {
      OmnigentDesktopCommands(
        actions: DesktopCommandActions(
          defaultServerURL: { desktop.preferences.defaultServerURL },
          helpURL: URL(string: "https://github.com/omnigent-ai/omnigent"),
          exportDiagnostics: { print("export diagnostics") },
          checkForUpdates: { print("check for updates") },
          localServer: desktop.localServer))
    }

    LocalServerLogsWindow(manager: desktop.localServer)

    OmnigentMenuBarExtra(desktop: desktop, sessions: ExampleSessions.source)

    Settings {
      OmnigentSettingsView(
        desktop: desktop, recentServers: ExampleWindow.knownServers,
        exportDiagnostics: { print("export diagnostics") })
    }
  }
}

/// Uses an isolated controller for `--screenshots`, so the run never touches the user's
/// settings or `~/.omnigent`.
final class ExampleAppDelegate: OmnigentDesktopAppDelegate {
  // Not `override`: the superclass's `init()` is a convenience initializer.
  init() {
    super.init(desktop: Screenshots.isolatedDesktop() ?? DesktopController())
  }
}

/// Sample sessions for the menu bar extra until the stores provide real ones.
enum ExampleSessions {
  static let source = ExampleWindow.knownServers.first.map {
    FakeMenuBarSessionSource.sample(serverURL: $0)
  }
}

struct ExampleWindow: View {
  static let knownServers = [URL(string: "http://localhost:8000")].compactMap(\.self)

  @Binding var id: ServerWindowID
  let desktop: DesktopController
  @State private var route: DeepLinkRoute = .home
  @State private var isReady = false
  @Environment(\.openSettings) private var openSettings

  private var viewedSessionID: String? {
    guard case .conversation(let sessionID) = route else { return nil }
    return sessionID
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent("Server", value: id.serverURL?.absoluteString ?? "Connect screen")
      LabeledContent("Route", value: route.path)
      LabeledContent("Windows", value: String(desktop.registry.entries.count))
      HStack {
        Button("Connect to localhost:8000") {
          id = id.rebound(to: Self.knownServers.first)
          isReady = true
        }
        Button("Open deep link") {
          desktop.router.open(
            [URL(string: "omnigent://localhost:8000/c/conv_demo")].compactMap(\.self))
        }
      }
      TextField("Find target", text: .constant("Text views keep the standard find bar"))
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .navigationTitle(id.serverURL?.host() ?? "Omnigent")
    .serverWindow(
      $id, desktop: desktop, isReady: isReady && id.serverURL != nil,
      viewedSessionID: viewedSessionID, unreadCount: 2,
      actions: ServerWindowActions(
        newSession: { route = .home },
        changeServer: {
          id = id.rebound(to: nil)
          isReady = false
        },
        signOut: id.serverURL == nil ? nil : { print("sign out") },
        reconnect: { print("reconnect") },
        zoom: .init(reset: {}, zoomIn: {}, zoomOut: {})),
      onRoute: { route = $0 }
    )
    .windowFrameAutosave()
    .onAppear {
      desktop.router.knownServers = { Self.knownServers }
      if id.serverURL != nil { isReady = true }
    }
    .task { await SelfTest.runIfRequested(desktop: desktop, openSettings: openSettings) }
    .task { await Screenshots.runIfRequested(desktop: desktop) }
  }
}

enum SelfTest {
  private static var started = false

  static func runIfRequested(desktop: DesktopController, openSettings: OpenSettingsAction) async {
    guard !started else { return }
    let argument = CommandLine.arguments.first { $0.hasPrefix("--report-after=") }
      .map { String($0.dropFirst("--report-after=".count)) }
    // `open -a <app> <url>` cannot pass arguments, so cold-start checks use the environment.
    let environment = ProcessInfo.processInfo.environment["OMNIGENT_EXAMPLE_REPORT_AFTER"]
    if let seconds = (argument ?? environment).flatMap(Double.init) {
      started = true
      await report(after: seconds, desktop: desktop)
      return
    }
    guard CommandLine.arguments.contains("--self-test") else { return }
    started = true
    do {
      NSApplication.shared.setActivationPolicy(.regular)
      NSApplication.shared.activate()
      try await Task.sleep(for: .seconds(1))
      print(
        "active: \(NSApplication.shared.isActive), key window: \(desktop.registry.keyWindow != nil)"
      )
      printMenus()
      desktop.router.open([URL(string: "omnigent://localhost:8000/c/conv_demo")].compactMap(\.self))
      try await Task.sleep(for: .seconds(2))
      for entry in desktop.registry.entries {
        print(
          "window \(entry.id.serverURL?.absoluteString ?? "connect-screen") ready=\(entry.isReady)"
            + " viewing=\(entry.viewedSessionID ?? "-") unread=\(entry.unreadCount)")
      }
      print("dock badge: \(NSApplication.shared.dockTile.badgeLabel ?? "none")")
      openSettings()
      try await Task.sleep(for: .seconds(1))
      let titles = NSApplication.shared.windows.filter(\.isVisible).map(\.title)
      print("visible windows: \(titles)")
    } catch {
      print("self-test interrupted: \(error)")
    }
    NSApplication.shared.terminate(nil)
  }

  /// Waits while URLs are opened from outside (`open -a`), then prints the windows and quits.
  private static func report(after seconds: Double, desktop: DesktopController) async {
    do {
      try await Task.sleep(for: .seconds(seconds))
    } catch {
      print("report interrupted: \(error)")
    }
    let visible = NSApplication.shared.windows.filter { $0.isVisible && $0.canBecomeMain }
    print("visible windows: \(visible.count)")
    for entry in desktop.registry.entries {
      print(
        "window \(entry.id.serverURL?.absoluteString ?? "connect-screen") ready=\(entry.isReady)"
          + " viewing=\(entry.viewedSessionID ?? "-")")
    }
    NSApplication.shared.terminate(nil)
  }

  private static func printMenus() {
    guard let mainMenu = NSApplication.shared.mainMenu else {
      print("no main menu")
      return
    }
    mainMenu.update()
    for top in mainMenu.items {
      print("[\(top.title)]")
      guard let submenu = top.submenu else { continue }
      // SwiftUI refreshes command state when a menu is about to open.
      submenu.delegate?.menuNeedsUpdate?(submenu)
      submenu.update()
      printItems(submenu, depth: 1)
    }
  }

  private static func printItems(_ menu: NSMenu, depth: Int) {
    for item in menu.items where !item.isHidden {
      let indent = String(repeating: "  ", count: depth)
      if item.isSeparatorItem {
        print("\(indent)---")
        continue
      }
      let shortcut = item.keyEquivalent.isEmpty ? "" : "  \(modifiers(item))\(item.keyEquivalent)"
      print("\(indent)\(item.title)\(shortcut)\(item.isEnabled ? "" : "  (disabled)")")
      if let submenu = item.submenu, depth < 2 { printItems(submenu, depth: depth + 1) }
    }
  }

  private static func modifiers(_ item: NSMenuItem) -> String {
    let mask = item.keyEquivalentModifierMask
    return (mask.contains(.control) ? "ctrl-" : "") + (mask.contains(.option) ? "opt-" : "")
      + (mask.contains(.shift) ? "shift-" : "") + (mask.contains(.command) ? "cmd-" : "")
  }
}
