import AppKit
public import SwiftUI

/// App-wide menu actions that do not depend on the key window.
public struct DesktopCommandActions {
  /// The server for a new window when no server window is key.
  public var defaultServerURL: () -> URL?
  /// Opened by Help > Omnigent Help; the item is hidden when `nil`.
  public var helpURL: URL?
  /// Help > Export Diagnostics...; hidden when `nil`.
  public var exportDiagnostics: (() -> Void)?
  /// Omnigent > Check for Updates...; hidden when `nil`. Bind to Sparkle's updater.
  public var checkForUpdates: (() -> Void)?
  /// Adds the local server and host items to the Server menu; hidden when `nil` or when the
  /// edition cannot spawn processes. Normally `desktop.localServer`.
  public var localServer: LocalServerManager?

  /// Creates app actions.
  /// - Parameters:
  ///   - defaultServerURL: Server for new windows.
  ///   - helpURL: Documentation URL.
  ///   - exportDiagnostics: Diagnostics export.
  ///   - checkForUpdates: Update check.
  ///   - localServer: The local server manager for the Server menu.
  public init(
    defaultServerURL: @escaping () -> URL?,
    helpURL: URL? = nil,
    exportDiagnostics: (() -> Void)? = nil,
    checkForUpdates: (() -> Void)? = nil,
    localServer: LocalServerManager? = nil
  ) {
    self.defaultServerURL = defaultServerURL
    self.helpURL = helpURL
    self.exportDiagnostics = exportDiagnostics
    self.checkForUpdates = checkForUpdates
    self.localServer = localServer
  }
}

/// The Omnigent menu bar, mirroring the Electron app's menus with native placement.
///
/// - Omnigent: About, Check for Updates..., Settings... (from the `Settings` scene).
/// - File: New Session, New Window, New Window on Different Server..., then the standard Close
///   and Close All. Electron has no File menu and lists these under Server; on macOS they stay
///   in File so Close Window keeps its place and Command-W.
/// - Edit: the standard Undo, Redo and pasteboard items, then Find.
/// - View: Reconnect and zoom, then the standard toolbar, sidebar, inspector and full-screen
///   items.
/// - Server: Change Server... and Sign Out of Server, then (with `actions.localServer`) Start
///   Server on This Mac, Stop Server, Start Host on This Mac..., Stop Host and Show Server Logs.
/// - Window: the standard window list, tiling and tabs.
/// - Help: Omnigent Help and Export Diagnostics....
///
/// Window-specific items act on the key window's `ServerWindowActions` and are disabled when it
/// does not provide them.
public struct OmnigentDesktopCommands: Commands {
  @FocusedValue(\.serverWindow) private var focused
  @Environment(\.openWindow) private var openWindow
  private let actions: DesktopCommandActions

  /// Creates the commands.
  /// - Parameter actions: App-wide actions.
  public init(actions: DesktopCommandActions) {
    self.actions = actions
  }

  /// The menu bar content.
  public var body: some Commands {
    SidebarCommands()
    ToolbarCommands()
    InspectorCommands()
    CommandGroup(replacing: .newItem) {
      newItems
    }
    CommandGroup(after: .appInfo) {
      if let checkForUpdates = actions.checkForUpdates {
        Button("Check for Updates\u{2026}", action: checkForUpdates)
      }
    }
    CommandGroup(after: .pasteboard) {
      Divider()
      FindMenu(find: focused?.actions.find)
    }
    CommandGroup(before: .toolbar) {
      viewItems
    }
    CommandMenu("Server") {
      serverItems
    }
    CommandGroup(replacing: .help) {
      if let helpURL = actions.helpURL {
        Button("Omnigent Help") { NSWorkspace.shared.open(helpURL) }
      }
      if let exportDiagnostics = actions.exportDiagnostics {
        Button("Export Diagnostics\u{2026}", action: exportDiagnostics)
      }
    }
  }

  @ViewBuilder private var newItems: some View {
    Button("New Session") { focused?.actions.newSession?() }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(focused?.actions.newSession == nil)
    Button("New Window") {
      openWindow(value: ServerWindowID.newWindow(serverURL: newWindowServerURL()))
    }
    .keyboardShortcut("n", modifiers: [.command, .shift])
    Button("New Window on Different Server\u{2026}") {
      openWindow(value: ServerWindowID.newWindow(serverURL: nil))
    }
  }

  @ViewBuilder private var serverItems: some View {
    let window = focused?.actions
    Button("Change Server\u{2026}") { window?.changeServer?() }
      .disabled(window?.changeServer == nil)
    Button("Sign Out of Server") { window?.signOut?() }
      .disabled(window?.signOut == nil)
    if let manager = actions.localServer, manager.capability.isAvailable {
      localServerItems(manager)
    }
  }

  @ViewBuilder private func localServerItems(_ manager: LocalServerManager) -> some View {
    let hostFallback = focused?.id.serverURL
    Divider()
    Button("Start Server on This Mac") { LocalServerActions.startServer(manager) }
      .disabled(!manager.server.canStart)
    Button("Stop Server") { LocalServerActions.stopServer(manager) }
      .disabled(!manager.server.canStop)
    Divider()
    Button("Start Host on This Mac\u{2026}") {
      LocalServerActions.startHost(manager, fallback: hostFallback)
    }
    .disabled(
      !manager.host.canStart || (manager.server.endpoint == nil && hostFallback == nil))
    Button("Stop Host") { LocalServerActions.stopHost(manager) }
      .disabled(!manager.host.canStop)
    Divider()
    Button("Show Server Logs") { openWindow(id: LocalServerLogsWindow.id) }
  }

  @ViewBuilder private var viewItems: some View {
    let window = focused?.actions
    // Command-R reloads a browser tab and Option-Command-R renames the session.
    Button("Reconnect") { window?.reconnect?() }
      .keyboardShortcut("r", modifiers: [.command, .option, .shift])
      .disabled(window?.reconnect == nil)
    Divider()
    Button("Actual Size") { window?.zoom?.reset() }
      .keyboardShortcut("0", modifiers: .command)
      .disabled(window?.zoom == nil)
    Button("Zoom In") { window?.zoom?.zoomIn() }
      .keyboardShortcut("+", modifiers: .command)
      .disabled(window?.zoom == nil)
    Button("Zoom Out") { window?.zoom?.zoomOut() }
      .keyboardShortcut("-", modifiers: .command)
      .disabled(window?.zoom == nil)
  }

  /// New windows open on the key window's server, else the default server.
  private func newWindowServerURL() -> URL? {
    if let focused { return focused.id.serverURL }
    return actions.defaultServerURL()
  }
}

/// Edit > Find. Without window find actions it forwards to the first responder's `NSTextFinder`,
/// so text views keep their standard find bar.
struct FindMenu: View {
  let find: ServerWindowActions.Find?

  var body: some View {
    Menu("Find") {
      Button("Find\u{2026}") {
        if let find { find.show() } else { Self.sendTextFinderAction(.showFindInterface) }
      }
      .keyboardShortcut("f", modifiers: .command)
      Button("Find Next") {
        if let find { find.next() } else { Self.sendTextFinderAction(.nextMatch) }
      }
      .keyboardShortcut("g", modifiers: .command)
      Button("Find Previous") {
        if let find { find.previous() } else { Self.sendTextFinderAction(.previousMatch) }
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      Button("Use Selection for Find") {
        if let find {
          find.useSelection?()
        } else {
          Self.sendTextFinderAction(.setSearchString)
        }
      }
      .keyboardShortcut("e", modifiers: .command)
      .disabled(find != nil && find?.useSelection == nil)
    }
  }

  /// `performTextFinderAction(_:)` reads the action from the sender's `tag`.
  static func sendTextFinderAction(_ action: NSTextFinder.Action) {
    let sender = NSMenuItem()
    sender.tag = action.rawValue
    let handled = NSApplication.shared.sendAction(
      #selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    if !handled { NSSound.beep() }
  }
}
