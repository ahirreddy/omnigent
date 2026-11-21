import AppKit
public import SwiftUI

/// App-wide menu actions that do not depend on the key window.
public struct DesktopCommandActions {
  /// The server for a new window when no server window is key.
  public var defaultServerURL: () -> URL?
  /// Opened by Help > Omnigent Help; the item is hidden when `nil`.
  public var helpURL: URL?
  /// Omnigent > Check for Updates...; hidden when `nil`. Bind to Sparkle's updater.
  public var checkForUpdates: (() -> Void)?
  /// Omnigent > Settings... (Command-comma) for an app that shows Settings in its windows;
  /// `nil` leaves the item to a `Settings` scene.
  public var showSettings: (() -> Void)?
  /// Adds the local server and host items to the Server menu; hidden when `nil` or when the
  /// edition cannot spawn processes. Normally `desktop.localServer`.
  public var localServer: LocalServerManager?

  /// Creates app actions.
  /// - Parameters:
  ///   - defaultServerURL: Server for new windows.
  ///   - helpURL: Documentation URL.
  ///   - checkForUpdates: Update check.
  ///   - showSettings: Shows Settings in the front window.
  ///   - localServer: The local server manager for the Server menu.
  public init(
    defaultServerURL: @escaping () -> URL?,
    helpURL: URL? = nil,
    checkForUpdates: (() -> Void)? = nil,
    showSettings: (() -> Void)? = nil,
    localServer: LocalServerManager? = nil
  ) {
    self.defaultServerURL = defaultServerURL
    self.helpURL = helpURL
    self.checkForUpdates = checkForUpdates
    self.showSettings = showSettings
    self.localServer = localServer
  }
}

/// The Omnigent menu bar, mirroring the Electron app's menus with native placement.
///
/// - Omnigent: About, Check for Updates..., Settings... (the front window's Settings page with
///   `actions.showSettings`, else a `Settings` scene's).
/// - File: New Session, New Window, New Window on Different Server..., then the standard Close
///   and Close All. Electron has no File menu and lists these under Server; on macOS they stay
///   in File so Close Window keeps its place and Command-W.
/// - Edit: the standard Undo, Redo and pasteboard items, then Find.
/// - View: Reconnect and zoom, then the standard toolbar, sidebar, inspector and full-screen
///   items.
/// - Server: Change Server... and Sign Out of Server, then (with `actions.localServer`) Start
///   Server on This Mac, Stop Server, Start Host on This Mac..., Stop Host and Show Server Logs.
/// - Window: the standard window list, tiling and tabs.
/// - Help: Omnigent Help.
///
/// Window-specific items act on the key window's `ServerWindowActions` and are disabled when it
/// does not provide them.
public struct OmnigentDesktopCommands: Commands {
  @FocusedValue(\.serverWindow) private var focused
  @Environment(\.openWindow) private var openWindow
  private let actions: DesktopCommandActions
  private let find: ServerWindowActions.Find?

  /// Creates the commands.
  /// - Parameters:
  ///   - actions: App-wide actions.
  ///   - find: Edit > Find for what has the keyboard, ahead of the key window's own.
  public init(actions: DesktopCommandActions, find: ServerWindowActions.Find? = nil) {
    self.actions = actions
    self.find = find
  }

  /// The menu bar content.
  public var body: some Commands {
    SidebarCommands()
    ToolbarCommands()
    InspectorCommands()
    CommandGroup(replacing: .newItem) {
      NewWindowMenuItems(
        window: focused, defaultServerURL: actions.defaultServerURL,
        openServerWindow: { openWindow(value: $0) })
    }
    CommandGroup(after: .appInfo) {
      UpdateMenuItems(actions: actions)
    }
    if let showSettings = actions.showSettings {
      CommandGroup(replacing: .appSettings) {
        SettingsMenuItem(showSettings: showSettings)
      }
    }
    CommandGroup(after: .pasteboard) {
      Divider()
      FindMenu(find: find ?? focused?.actions.find)
    }
    CommandGroup(before: .toolbar) {
      ViewMenuItems(window: focused?.actions)
    }
    CommandMenu("Server") {
      ServerMenuItems(
        window: focused, localServer: actions.localServer,
        showLogs: { openWindow(id: LocalServerLogsWindow.id) })
    }
    CommandGroup(replacing: .help) {
      HelpMenuItems(actions: actions)
    }
  }
}

/// Omnigent: Check for Updates, hidden where the edition doesn't update itself.
struct UpdateMenuItems: View {
  let actions: DesktopCommandActions

  var body: some View {
    if let checkForUpdates = actions.checkForUpdates {
      Button("Check for Updates\u{2026}", action: checkForUpdates)
    }
  }
}

/// Omnigent > Settings.
struct SettingsMenuItem: View {
  let showSettings: () -> Void

  var body: some View {
    Button("Settings\u{2026}", action: showSettings)
      .keyboardShortcut(",", modifiers: .command)
  }
}

/// File: New Session, New Window and New Window on Different Server.
struct NewWindowMenuItems: View {
  let window: FocusedServerWindow?
  let defaultServerURL: () -> URL?
  let openServerWindow: (ServerWindowID) -> Void

  var body: some View {
    Button("New Session") { window?.actions.newSession?() }
      .keyboardShortcut("n", modifiers: .command)
      .disabled(window?.actions.newSession == nil)
    Button("New Window") {
      // New windows open on the key window's server, else the default server.
      let server = window.map(\.id.serverURL) ?? defaultServerURL()
      openServerWindow(ServerWindowID.newWindow(serverURL: server))
    }
    .keyboardShortcut("n", modifiers: [.command, .shift])
    Button("New Window on Different Server\u{2026}") {
      openServerWindow(ServerWindowID.newWindow(serverURL: nil))
    }
  }
}

/// Server: the key window's server items, then this Mac's local server items.
struct ServerMenuItems: View {
  let window: FocusedServerWindow?
  let localServer: LocalServerManager?
  let showLogs: () -> Void

  var body: some View {
    Button("Change Server\u{2026}") { window?.actions.changeServer?() }
      .disabled(window?.actions.changeServer == nil)
    Button("Sign Out of Server") { window?.actions.signOut?() }
      .disabled(window?.actions.signOut == nil)
    if let manager = localServer, manager.capability.isAvailable {
      localServerItems(manager)
    }
  }

  @ViewBuilder private func localServerItems(_ manager: LocalServerManager) -> some View {
    let hostFallback = window?.id.serverURL
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
    Button("Show Server Logs", action: showLogs)
  }
}

/// View: Reconnect and zoom.
struct ViewMenuItems: View {
  let window: ServerWindowActions?

  var body: some View {
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
}

/// Help: Omnigent Help, hidden without its page.
struct HelpMenuItems: View {
  let actions: DesktopCommandActions

  var body: some View {
    if let helpURL = actions.helpURL {
      Button("Omnigent Help") { NSWorkspace.shared.open(helpURL) }
    }
  }
}

/// Edit > Find. Without window find actions it forwards to the first responder's `NSTextFinder`,
/// so text views keep their standard find bar.
struct FindMenu: View {
  let find: ServerWindowActions.Find?

  var body: some View {
    Menu("Find") {
      Button("Find\u{2026}") {
        if let find {
          find.show()
        } else {
          // A line selected in a text view becomes the query, as in browsers and editors.
          if Self.seedsFind(from: NSApplication.shared.keyWindow?.firstResponder) {
            Self.sendTextFinderAction(.setSearchString)
          }
          Self.sendTextFinderAction(.showFindInterface)
        }
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

  /// Longest selection that seeds the query; longer ones leave it unchanged.
  static let maxSeedLength = 1000

  /// Whether Find should take `responder`'s selection as its query: a text view's (not a find
  /// field's own editor) single trimmed line of at most ``maxSeedLength`` characters.
  static func seedsFind(from responder: NSResponder?) -> Bool {
    guard let textView = responder as? NSTextView, !textView.isFieldEditor else { return false }
    let range = textView.selectedRange()
    let text = textView.string
    guard range.length > 0, range.length <= maxSeedLength * 4,
      let selected = Range(range, in: text)
    else { return false }
    let line = text[selected].trimmingCharacters(in: .whitespacesAndNewlines)
    return !line.isEmpty && !line.contains(where: \.isNewline) && line.count <= maxSeedLength
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
