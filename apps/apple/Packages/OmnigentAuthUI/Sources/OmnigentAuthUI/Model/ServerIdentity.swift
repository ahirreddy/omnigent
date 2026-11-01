public import Foundation

/// What the client knows about a server before and while signing in.
///
/// Field names follow `omnigent-ffi` `ServerDiscovery` (`base_url`, `server_name`,
/// `server_version`) and the Rust `AuthenticationDiscovery` (`mode`, `needs_setup`).
public nonisolated struct ServerIdentity: Hashable, Sendable {
  /// The canonical API root, mount path included.
  public var baseUrl: String
  /// The operator's display name, from the manifest. Display only, never for trust decisions.
  public var serverName: String?
  /// The server package version, informational.
  public var serverVersion: String?
  /// How it signs users in, once known.
  public var mode: SignInMode?
  /// Accounts mode with no admin yet: first-time setup must happen in the web app.
  public var needsSetup: Bool

  /// Creates an identity.
  /// - Parameters:
  ///   - baseUrl: The canonical API root.
  ///   - serverName: The operator's display name.
  ///   - serverVersion: The server package version.
  ///   - mode: How it signs users in.
  ///   - needsSetup: Whether first-time setup is still pending.
  public init(
    baseUrl: String, serverName: String? = nil, serverVersion: String? = nil,
    mode: SignInMode? = nil, needsSetup: Bool = false
  ) {
    self.baseUrl = baseUrl
    self.serverName = serverName
    self.serverVersion = serverVersion
    self.mode = mode
    self.needsSetup = needsSetup
  }

  /// `host[:port]` of ``baseUrl``, or ``baseUrl`` itself when it does not parse.
  public var hostLabel: String { Self.hostLabel(baseUrl) }

  /// The name to show: ``serverName`` when set, otherwise ``hostLabel``.
  public var displayName: String {
    if let serverName, !serverName.trimmingCharacters(in: .whitespaces).isEmpty {
      return ServerText.escaped(serverName, limit: 80)
    }
    return hostLabel
  }

  /// The web app's address, for "Open in Browser".
  public var webURL: URL? { URL(string: baseUrl) }

  /// `host[:port]` for `url`; the input when it has no host.
  /// - Parameter url: A server URL.
  /// - Returns: The host label.
  public static func hostLabel(_ url: String) -> String {
    guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty
    else {
      return ServerText.escaped(url, limit: 120)
    }
    if let port = components.port { return "\(host):\(port)" }
    return host
  }
}

/// The account a connection confirmed.
///
/// Mirrors `omnigent-ffi` `ConnectedServer`.
public nonisolated struct SignedInAccount: Hashable, Sendable {
  /// The canonical API root.
  public var baseUrl: String
  /// The operator's display name, from the manifest.
  public var serverName: String?
  /// The confirmed user id (`local` on a single-user server).
  public var userId: String
  /// The per-account scope key (server plus user).
  public var accountId: String
  /// How the server authenticates.
  public var mode: SignInMode

  /// Creates an account.
  /// - Parameters:
  ///   - baseUrl: The canonical API root.
  ///   - serverName: The operator's display name.
  ///   - userId: The confirmed user id.
  ///   - accountId: The per-account scope key.
  ///   - mode: How the server authenticates.
  public init(
    baseUrl: String, serverName: String? = nil, userId: String, accountId: String,
    mode: SignInMode
  ) {
    self.baseUrl = baseUrl
    self.serverName = serverName
    self.userId = userId
    self.accountId = accountId
    self.mode = mode
  }

  /// The server this account is on.
  public var server: ServerIdentity {
    ServerIdentity(baseUrl: baseUrl, serverName: serverName, mode: mode)
  }

  /// The user to show. A single-user server's `local` reads as "Local user".
  public var userLabel: String {
    mode == .localSingleUser ? "Local user" : ServerText.escaped(userId, limit: 80)
  }

  /// Whether the user can sign out: a single-user server has nothing to sign out of.
  public var canSignOut: Bool { mode != .localSingleUser }
}

/// A browser-ticket sign-in waiting for approval.
///
/// Mirrors `omnigent-ffi` `BrowserLoginInfo`. ``loginUrl`` carries the ticket, so views open it but
/// never print it.
public nonisolated struct BrowserApproval: Hashable, Sendable {
  /// The page the user opens to approve the sign-in.
  public var loginUrl: String
  /// The code the page shows, when the server sent one. Not a secret: the user matches it.
  public var userCode: String?
  /// When the ticket expires, in milliseconds since the Unix epoch.
  public var expiresAtMs: UInt64

  /// Creates an approval.
  /// - Parameters:
  ///   - loginUrl: The page the user opens.
  ///   - userCode: The code the page shows.
  ///   - expiresAtMs: When the ticket expires, in ms since the Unix epoch.
  public init(loginUrl: String, userCode: String? = nil, expiresAtMs: UInt64) {
    self.loginUrl = loginUrl
    self.userCode = userCode
    self.expiresAtMs = expiresAtMs
  }

  /// When the ticket expires.
  public var expiresAt: Date { Date(timeIntervalSince1970: Double(expiresAtMs) / 1_000) }
}

/// An organization server from managed (MDM) preferences.
///
/// Mirrors `omnigent-ffi` `ManagedServer`.
public nonisolated struct ManagedServerEntry: Hashable, Sendable, Identifiable {
  /// The server URL.
  public var url: String
  /// The administrator's name for it.
  public var name: String?
  /// Its origin.
  public var origin: String
  /// `host[:port]`.
  public var authority: String
  /// The name, or the host.
  public var displayName: String

  /// Creates an entry.
  /// - Parameters:
  ///   - url: The server URL.
  ///   - name: The administrator's name for it.
  ///   - origin: Its origin.
  ///   - authority: `host[:port]`.
  ///   - displayName: The name, or the host.
  public init(url: String, name: String?, origin: String, authority: String, displayName: String) {
    self.url = url
    self.name = name
    self.origin = origin
    self.authority = authority
    self.displayName = displayName
  }

  /// The URL identifies the entry.
  public var id: String { url }
}

/// The servers the picker offers.
///
/// ``managed`` and ``serversAreForced`` mirror `omnigent-ffi` `ManagedServers`. ``recentServers``
/// is `SettingsStore.recent_servers()` after Rust `recents_excluding_managed`, newest first.
public nonisolated struct ServerDirectory: Hashable, Sendable {
  /// Organization servers, most preferred first.
  public var managed: [ManagedServerEntry]
  /// An MDM profile forces the organization servers.
  public var serversAreForced: Bool
  /// The user's recent servers that are not organization servers, newest first.
  public var recentServers: [String]

  /// Creates a directory.
  /// - Parameters:
  ///   - managed: Organization servers.
  ///   - serversAreForced: Whether an MDM profile forces them.
  ///   - recentServers: Recent servers, newest first.
  public init(
    managed: [ManagedServerEntry] = [], serversAreForced: Bool = false, recentServers: [String] = []
  ) {
    self.managed = managed
    self.serversAreForced = serversAreForced
    self.recentServers = recentServers
  }

  /// No servers to offer.
  public var isEmpty: Bool { managed.isEmpty && recentServers.isEmpty }
}
