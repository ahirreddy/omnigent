/// A destination or action offered by the command palette.
nonisolated public enum PaletteTarget: Hashable, Sendable {
  /// Search only sessions.
  case findSession
  /// Start a session.
  case newSession
  /// Move to the next waiting session.
  case nextRequest
  /// Show the selected session's Changes tab.
  case changes
  /// Search configured servers.
  case switchServer
  /// Focus the selected session's draft.
  case composer
  /// Switch chat and terminal.
  case toggleTerminal
  /// Open triage.
  case inbox
  /// Open a particular session.
  case session(String)
  /// Connect to a configured server.
  case server(String)
}

/// One searchable palette result.
nonisolated public struct PaletteEntry: Hashable, Sendable, Identifiable {
  /// Stable result identity.
  public var id: String
  /// Visible action or session name.
  public var title: String
  /// Scope, execution context or status preview.
  public var detail: String
  /// SF Symbol for the result.
  public var symbol: String
  /// Keyboard equivalent, when one exists.
  public var shortcut: String
  /// Whether the action is available in the current scope.
  public var isEnabled: Bool
  /// Destination to execute.
  public var target: PaletteTarget

  /// Creates a palette entry.
  public init(
    id: String, title: String, detail: String = "", symbol: String,
    shortcut: String = "", isEnabled: Bool = true, target: PaletteTarget
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.shortcut = shortcut
    self.isEnabled = isEnabled
    self.target = target
  }
}

/// The palette's window-local search data.
nonisolated public struct PaletteViewState: Hashable, Sendable {
  /// Current server's display name.
  public var scope: String
  /// Available sessions, newest first.
  public var sessions: [PaletteEntry]
  /// Configured servers, in preference order.
  public var servers: [PaletteEntry]
  /// Whether the shared attention model has a next request.
  public var hasNextRequest: Bool

  /// Creates palette data without loading or searching over the network.
  public init(
    scope: String, sessions: [PaletteEntry], servers: [PaletteEntry] = [],
    hasNextRequest: Bool = false
  ) {
    self.scope = scope
    self.sessions = sessions
    self.servers = servers
    self.hasNextRequest = hasNextRequest
  }
}

/// Window-local navigation supplied by the app assembly.
public struct PaletteActions {
  /// Executes a destination after dismissing the palette.
  public var perform: @MainActor (PaletteTarget) -> Void

  /// Creates navigation actions.
  public init(perform: @escaping @MainActor (PaletteTarget) -> Void) {
    self.perform = perform
  }
}
