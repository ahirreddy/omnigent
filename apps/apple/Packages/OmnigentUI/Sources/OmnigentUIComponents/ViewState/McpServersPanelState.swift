public import Foundation

/// The `/mcp` panel over a started session's composer (the web's `McpServerMenu`): the
/// session's MCP servers with their account and live state, and what each row offers.
nonisolated public struct McpServersPanelState: Hashable, Sendable {
  /// A row's leading symbol.
  public enum Symbol: Hashable, Sendable {
    /// Failed in the session.
    case failed
    /// Connecting in the session.
    case connecting
    /// Needs signing in.
    case needsSignIn
    /// The account no longer sees the service.
    case unavailable
    /// Connected.
    case connected
    /// Nothing reported.
    case idle
  }

  /// How a status line reads.
  public enum Tone: Hashable, Sendable {
    /// Plain.
    case secondary
    /// Needs attention.
    case warning
    /// Failed.
    case failure
  }

  /// A row's button.
  public enum Action: Hashable, Sendable {
    /// "Sign in" on a web page: the host's sign-in page or the server's MCP settings.
    case signIn(URL)
    /// "Sign in from Settings", where a token or workspace URL is typed.
    case signInFromSettings
    /// "Reconnect" the session's live server, by the harness's name.
    case reconnect(name: String, isReconnecting: Bool, isEnabled: Bool)
  }

  /// One server.
  public struct Row: Hashable, Sendable, Identifiable {
    /// Unique among the rows.
    public var id: String
    /// The server's name.
    public var name: String
    /// Its plugin and URL host, or what it does.
    public var detail: String?
    /// The leading symbol.
    public var symbol: Symbol
    /// Its account state, as "Connected" or "Account: Sign-in required".
    public var account: String?
    /// How ``account`` reads.
    public var accountTone: Tone = .secondary
    /// Its connection in the session, as "In this session: Failed: …".
    public var live: String?
    /// How ``live`` reads.
    public var liveTone: Tone = .secondary
    /// Its button.
    public var action: Action?
    /// A sign-in or reconnect that failed for it.
    public var error: String?

    /// Creates a row.
    /// - Parameters:
    ///   - id: Unique id.
    ///   - name: Name.
    ///   - detail: Plugin and URL host, or description.
    ///   - symbol: Leading symbol.
    public init(id: String, name: String, detail: String? = nil, symbol: Symbol = .idle) {
      self.id = id
      self.name = name
      self.detail = detail
      self.symbol = symbol
    }
  }

  /// The servers.
  public var rows: [Row]
  /// Why rows may be missing, or where live status comes from.
  public var status: String?
  /// A reconnect that failed for a server no row names.
  public var failure: String?
  /// The panel has not been read yet.
  public var isLoading: Bool

  /// Creates the panel.
  /// - Parameters:
  ///   - rows: Servers.
  ///   - status: Status line.
  ///   - failure: Unmatched reconnect failure.
  ///   - isLoading: Not read yet.
  public init(
    rows: [Row] = [], status: String? = nil, failure: String? = nil, isLoading: Bool = false
  ) {
    self.rows = rows
    self.status = status
    self.failure = failure
    self.isLoading = isLoading
  }

  /// Whether the panel stands for `draft`: exactly `/mcp`, as on the web.
  public static func isRequested(by draft: String) -> Bool {
    draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/mcp"
  }
}

/// What the `/mcp` panel does. `nil` hides a control.
public struct McpServersPanelActions {
  /// Reads the panel while it shows, until the task is cancelled.
  public var watch: (@MainActor () async -> Void)?
  /// A row's button.
  public var perform: (@MainActor (McpServersPanelState.Action) -> Void)?
  /// "Go to Settings": the harness settings, for configuring MCP servers.
  public var openSettings: (@MainActor () -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - watch: Reads the panel while it shows.
  ///   - perform: A row's button.
  ///   - openSettings: Go to Settings.
  public init(
    watch: (@MainActor () async -> Void)? = nil,
    perform: (@MainActor (McpServersPanelState.Action) -> Void)? = nil,
    openSettings: (@MainActor () -> Void)? = nil
  ) {
    self.watch = watch
    self.perform = perform
    self.openSettings = openSettings
  }
}
