/// Where the connection to a server stands.
///
/// Mirrors `omnigent-ffi` `ConnectionPhase` case for case and label for label, so the adapter maps
/// `CoreEvent.ConnectionChanged { phase }` with one switch. The one addition is the optional
/// `method` on ``signingIn(baseUrl:method:)``: the store knows which sign-in it started, and the UI
/// keeps the password form on screen while a password sign-in runs.
public nonisolated enum SignInPhase: Hashable, Sendable {
  /// Not connected.
  case disconnected
  /// Reading the manifest and `/v1/info`.
  case discovering(serverUrl: String)
  /// The server needs a sign-in the core cannot complete on its own.
  ///
  /// `methods` is what the app can offer, best first; empty when none works natively. `reason`
  /// says why a saved sign-in no longer works, when that is why.
  case signInRequired(
    baseUrl: String, serverName: String?, mode: SignInMode, methods: [SignInOption],
    reason: SignInError?)
  /// A sign-in is in progress. `method` is the option the store started, when it knows it.
  case signingIn(baseUrl: String, method: SignInOption? = nil)
  /// A browser-ticket sign-in waits for approval.
  case awaitingBrowserLogin(baseUrl: String, login: BrowserApproval)
  /// Confirming identity with the credential.
  case connecting(baseUrl: String)
  /// Connected; sessions load and stream.
  case connected(server: SignedInAccount)
  /// Connecting failed.
  case failed(serverUrl: String, error: SignInError)

  /// The server this phase is about, as typed or canonical; `nil` when disconnected.
  public var serverUrl: String? {
    switch self {
    case .disconnected: nil
    case .discovering(let serverUrl), .failed(let serverUrl, _): serverUrl
    case .signInRequired(let baseUrl, _, _, _, _), .signingIn(let baseUrl, _),
      .awaitingBrowserLogin(let baseUrl, _), .connecting(let baseUrl):
      baseUrl
    case .connected(let server): server.baseUrl
    }
  }
}
