public import SwiftUI

/// What the focused iPad scene's server can do from the hardware-keyboard menus. The Mac has
/// the same items in its desktop menus (`OmnigentDesktopCommands`); a `nil` action disables its
/// item.
public struct ServerCommandActions {
  /// Reconnect the scene's server (Option-Shift-Command-R).
  public var reconnect: (@MainActor () -> Void)?
  /// Leave the server for the server list.
  public var changeServer: (@MainActor () -> Void)?
  /// Sign out of a server with accounts.
  public var signOut: (@MainActor () -> Void)?
  /// Start a new session (Command-N).
  public var newSession: (@MainActor () -> Void)?
  /// Open another window on this server (Shift-Command-N), where the platform has windows.
  public var newWindow: (@MainActor () -> Void)?

  /// Creates the actions.
  /// - Parameters:
  ///   - reconnect: Reconnect.
  ///   - changeServer: Change server.
  ///   - signOut: Sign out.
  public init(
    reconnect: (@MainActor () -> Void)? = nil, changeServer: (@MainActor () -> Void)? = nil,
    signOut: (@MainActor () -> Void)? = nil
  ) {
    self.reconnect = reconnect
    self.changeServer = changeServer
    self.signOut = signOut
  }
}

extension ServerCommandActions: FocusedActions {
  /// Which commands are enabled.
  public var menuSignature: [Bool] {
    [reconnect != nil, changeServer != nil, signOut != nil, newSession != nil, newWindow != nil]
  }

  /// A copy whose commands call `latest`'s.
  /// - Parameter latest: The newest actions.
  /// - Returns: The forwarding copy.
  public func forwarding(to latest: @escaping @MainActor () -> Self?) -> Self {
    var copy = Self(
      reconnect: Self.forward(reconnect, \.reconnect, to: latest),
      changeServer: Self.forward(changeServer, \.changeServer, to: latest),
      signOut: Self.forward(signOut, \.signOut, to: latest))
    copy.newSession = Self.forward(newSession, \.newSession, to: latest)
    copy.newWindow = Self.forward(newWindow, \.newWindow, to: latest)
    return copy
  }
}

extension FocusedValues {
  /// The focused scene's server commands.
  @Entry public var serverCommands: ServerCommandActions?
  /// The focused iPhone or iPad scene's Settings screen.
  @Entry public var openSettingsScreen: OpenSettingsScreenAction?
}

/// View > Reconnect and the Server menu (Change Server, Sign Out) for iPad's menu bar and
/// keyboard. Add it with `.commands { OmnigentServerCommands() }`.
public struct OmnigentServerCommands: Commands {
  @FocusedValue(\.serverCommands) private var actions
  @FocusedValue(\.openSettingsScreen) private var openSettings

  /// Creates the commands.
  public init() {}

  /// The menus.
  public var body: some Commands {
    // File: New Session and New Window, as the Mac's desktop File menu.
    CommandGroup(replacing: .newItem) {
      ServerFileMenuItems(actions: actions)
    }
    // iPad's app menu: the Settings screen (Command-comma), as the Mac's Settings window.
    CommandGroup(replacing: .appSettings) {
      SettingsMenuItem(openSettings: openSettings)
    }
    CommandGroup(before: .toolbar) {
      ReconnectMenuItem(actions: actions)
    }
    CommandMenu("Server") {
      ServerMenuItems(actions: actions)
    }
  }
}

/// File > New Session and New Window.
struct ServerFileMenuItems: View {
  let actions: ServerCommandActions?

  var body: some View {
    Button("New Session") { actions?.newSession?() }
      .keyboardShortcut(AppShortcuts.newSession)
      .disabled(actions?.newSession == nil)
    Button("New Window") { actions?.newWindow?() }
      .keyboardShortcut(AppShortcuts.newWindow)
      .disabled(actions?.newWindow == nil)
  }
}

/// The app menu's Settings.
struct SettingsMenuItem: View {
  let openSettings: OpenSettingsScreenAction?

  var body: some View {
    Button("Settings\u{2026}") { openSettings?() }
      .keyboardShortcut(AppShortcuts.settings)
      .disabled(openSettings == nil)
  }
}

/// View > Reconnect.
struct ReconnectMenuItem: View {
  let actions: ServerCommandActions?

  var body: some View {
    // Command-R reloads a browser tab and Option-Command-R renames the session.
    Button("Reconnect") { actions?.reconnect?() }
      .keyboardShortcut(AppShortcuts.reconnect)
      .disabled(actions?.reconnect == nil)
  }
}

/// The Server menu.
struct ServerMenuItems: View {
  let actions: ServerCommandActions?

  var body: some View {
    Button("Change Server\u{2026}") { actions?.changeServer?() }
      .disabled(actions?.changeServer == nil)
    Button("Sign Out of Server") { actions?.signOut?() }
      .disabled(actions?.signOut == nil)
  }
}
