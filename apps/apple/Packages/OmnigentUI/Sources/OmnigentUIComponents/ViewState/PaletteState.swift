/// A destination or action offered by the command palette.
nonisolated public enum PaletteTarget: Hashable, Sendable {
  /// Search only sessions, by name.
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
  /// Open Automations.
  case automations
  /// Open Usage.
  case usage
  /// Open Settings.
  case settings
  /// Show or hide the sessions sidebar.
  case toggleSidebar
  /// Show or hide the selected session's right panel.
  case toggleInspector
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
  /// Other words that find it, unseen (an action's other names).
  public var keywords: [String]
  /// Destination to execute.
  public var target: PaletteTarget

  /// Creates a palette entry.
  public init(
    id: String, title: String, detail: String = "", symbol: String,
    shortcut: String = "", isEnabled: Bool = true, keywords: [String] = [],
    target: PaletteTarget
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.symbol = symbol
    self.shortcut = shortcut
    self.isEnabled = isEnabled
    self.keywords = keywords
    self.target = target
  }
}

/// Server search matches for a palette query, in the web's two groups.
nonisolated public struct PaletteSearchResults: Hashable, Sendable {
  /// Sessions whose title matches, or a disabled row saying the search failed.
  public var titles: [PaletteEntry]
  /// Sessions whose messages match ("In messages"), with the matching snippet.
  public var messages: [PaletteEntry]

  /// Creates results.
  /// - Parameters:
  ///   - titles: Title matches.
  ///   - messages: Message content matches.
  public init(titles: [PaletteEntry] = [], messages: [PaletteEntry] = []) {
    self.titles = titles
    self.messages = messages
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
  /// The server offers Automations, as the sidebar row is shown.
  public var showsAutomations = false
  /// The server offers Usage, as the sidebar row is shown.
  public var showsUsage = false

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
  /// Searches the server for sessions beyond the loaded list: title matches and message
  /// content matches ("In messages"). `nil` searches only the loaded sessions.
  public var search: (@MainActor (String) async -> PaletteSearchResults)?

  /// Creates navigation actions.
  /// - Parameters:
  ///   - perform: Executes a destination.
  ///   - search: Server-side session search.
  public init(
    perform: @escaping @MainActor (PaletteTarget) -> Void,
    search: (@MainActor (String) async -> PaletteSearchResults)? = nil
  ) {
    self.perform = perform
    self.search = search
  }
}
