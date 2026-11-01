/// How a server signs users in.
///
/// Mirrors `omnigent-ffi` `AuthenticationMode` (Rust `auth::mode::AuthenticationMode`) case for
/// case, so the adapter is a one-line switch.
public nonisolated enum SignInMode: Hashable, Sendable {
  /// An explicit loopback single-user server: no credentials.
  case localSingleUser
  /// Built-in username and password accounts.
  case accounts
  /// The server's OIDC sign-in in the system browser.
  case oidc
  /// Identity comes from in front of the server (a proxy, Databricks, an embedding app).
  case proxy
  /// A manifest mode newer than this client. Never mapped onto a known mode.
  case unsupported(mode: String)

  /// A short, user-facing name for the mode.
  public var displayName: String {
    switch self {
    case .localSingleUser: "Local, single user"
    case .accounts: "Username and password"
    case .oidc: "Single sign-on"
    case .proxy: "Proxy sign-in"
    case .unsupported(let mode): "Unsupported (\(ServerText.escaped(mode, limit: 40)))"
    }
  }
}

/// A way this app can sign in to a server, best first.
///
/// Mirrors `omnigent-ffi` `SignInMethod`, plus ``databricksWorkspace(workspaceHost:)`` for the
/// Databricks workspace OAuth flow (Rust `auth::databricks::LoginManager`), which the FFI does not
/// export yet.
public nonisolated enum SignInOption: Hashable, Sendable {
  /// Username and password (accounts mode).
  case password
  /// Native OIDC through the system sign-in sheet, redirecting to the app's registered scheme
  /// (`ai.omnigent.ios:/oauth/callback` on iOS).
  case browser(redirectUri: String)
  /// Native OIDC with an RFC 8252 loopback redirect (macOS).
  case loopbackBrowser(path: String)
  /// The OIDC browser-ticket fallback: open a page and wait for approval.
  case browserTicket
  /// Databricks workspace OAuth.
  case databricksWorkspace(workspaceHost: String)

  /// Whether this option signs in through a browser window or sheet.
  public var usesBrowser: Bool {
    switch self {
    case .password: false
    case .browser, .loopbackBrowser, .browserTicket, .databricksWorkspace: true
    }
  }

  /// The button title that starts this option.
  public var actionTitle: String {
    switch self {
    case .password: "Sign In"
    case .browser, .loopbackBrowser: "Continue in Browser"
    case .browserTicket: "Sign In with a Browser Link"
    case .databricksWorkspace: "Continue with Databricks"
    }
  }
}

/// What a sign-in failure means for the user.
///
/// Mirrors `omnigent-ffi` `AuthFailure` (Rust `auth::errors::AuthFailure`).
public nonisolated enum SignInFailure: Hashable, Sendable {
  /// The credential or grant outlived its lifetime; signing in again fixes it.
  case expired
  /// The server revoked or rejected the session or grant, or the account changed.
  case endedByServer
  /// There is no usable credential; the user must sign in.
  case signInRequired
  /// The server or identity provider declined the sign-in, with its reason when it gave one.
  case refused(reason: String?)
  /// The server could not be reached or answered unexpectedly; credentials are kept.
  case transport
  /// Anything else (invalid input, malformed response, storage failure).
  case failed

  /// Whether signing in again is the fix, which is when the UI asks "Sign in again?".
  public var asksToSignInAgain: Bool {
    switch self {
    case .expired, .endedByServer, .signInRequired: true
    case .refused, .transport, .failed: false
    }
  }
}
