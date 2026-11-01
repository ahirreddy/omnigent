/// Everything the sign-in UI renders.
///
/// The store builds it from core events: ``phase`` from `ConnectionChanged`, ``server`` from
/// `discover_server`, ``directory`` from `SettingsStore` and `ManagedPreferences`, ``notice`` from
/// sign-out and cancel outcomes.
public nonisolated struct AuthViewState: Hashable, Sendable {
  /// Where the connection stands.
  public var phase: SignInPhase
  /// The discovered server, for its version and setup state. Ignored when its ``ServerIdentity/baseUrl``
  /// is not the phase's server.
  public var server: ServerIdentity?
  /// The servers the picker offers.
  public var directory: ServerDirectory
  /// The last server the user tried, kept on cancel and failure to prefill the picker.
  public var lastServerUrl: String?
  /// A one-off informational message, for example Rust `signed_out_message` ("You're signed
  /// out of host.") or "Sign-in was cancelled."
  public var notice: String?

  /// Creates a state.
  /// - Parameters:
  ///   - phase: Where the connection stands.
  ///   - server: The discovered server.
  ///   - directory: The servers the picker offers.
  ///   - lastServerUrl: The last server the user tried.
  ///   - notice: A one-off informational message.
  public init(
    phase: SignInPhase = .disconnected, server: ServerIdentity? = nil,
    directory: ServerDirectory = ServerDirectory(), lastServerUrl: String? = nil,
    notice: String? = nil
  ) {
    self.phase = phase
    self.server = server
    self.directory = directory
    self.lastServerUrl = lastServerUrl
    self.notice = notice
  }

  /// The screen to show.
  public var screen: AuthScreen { AuthScreen(state: self) }

  /// The URL to prefill in the picker: the phase's server, else the last one tried.
  public var prefillServerUrl: String {
    if case .failed(let serverUrl, _) = phase { return serverUrl }
    return lastServerUrl ?? ""
  }

  /// The identity for `baseUrl`, using the discovered details when they are for the same server.
  /// - Parameters:
  ///   - baseUrl: The phase's server.
  ///   - serverName: The phase's display name, which wins over the discovered one.
  ///   - mode: The phase's mode, which wins over the discovered one.
  /// - Returns: The identity.
  public func identity(baseUrl: String, serverName: String? = nil, mode: SignInMode? = nil)
    -> ServerIdentity
  {
    var identity = ServerIdentity(baseUrl: baseUrl)
    if let server, server.baseUrl == baseUrl { identity = server }
    if let serverName { identity.serverName = serverName }
    if let mode { identity.mode = mode }
    return identity
  }
}
