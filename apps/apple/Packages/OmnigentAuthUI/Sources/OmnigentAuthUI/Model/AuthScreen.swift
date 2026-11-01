import Foundation

/// A message shown above a sign-in form.
public nonisolated enum AuthBanner: Hashable, Sendable {
  /// Information, for example "You're signed out of host."
  case notice(String)
  /// A failure, with Retry when it is retryable.
  case error(SignInError)
}

/// Why the user is asked to sign in again.
public nonisolated struct ReauthCause: Hashable, Sendable {
  /// The classification: ``SignInFailure/expired``, ``SignInFailure/endedByServer`` or
  /// ``SignInFailure/signInRequired``.
  public var failure: SignInFailure
  /// The core's message, which names the server and the cause (Rust
  /// `reauthentication_message`). Empty when the core sent none.
  public var message: String

  /// Creates a cause.
  /// - Parameters:
  ///   - failure: The classification.
  ///   - message: The core's message.
  public init(failure: SignInFailure, message: String) {
    self.failure = failure
    self.message = message
  }

  /// One line naming the cause.
  public var headline: String {
    switch failure {
    case .expired: "Your sign-in expired."
    case .endedByServer: "The server ended your session."
    case .signInRequired: "You need to sign in to continue."
    case .refused, .transport, .failed: "Your sign-in no longer works."
    }
  }

  /// What the prompt says: the core's message, which names the server and the cause, or
  /// ``headline`` when the core sent none.
  public var explanation: String {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? headline : ServerText.escaped(trimmed)
  }

  /// The SF Symbol for the cause.
  public var systemImage: String {
    switch failure {
    case .expired: "clock.badge.exclamationmark"
    case .endedByServer: "person.crop.circle.badge.xmark"
    case .signInRequired, .refused, .transport, .failed: "person.crop.circle.badge.questionmark"
    }
  }
}

/// The screen for an ``AuthViewState``: the state-to-view mapping, kept pure so it is tested
/// without rendering.
public nonisolated enum AuthScreen: Hashable, Sendable {
  /// The server picker, with a notice or the last connection failure.
  case serverPicker(banner: AuthBanner?)
  /// Reading the server's manifest.
  case discovering(serverUrl: String)
  /// The accounts form; `isSubmitting` while the password sign-in runs.
  case password(server: ServerIdentity, banner: AuthBanner?, isSubmitting: Bool)
  /// A browser sign-in to start, with any other options to offer.
  case browserSignIn(
    server: ServerIdentity, option: SignInOption, alternatives: [SignInOption], banner: AuthBanner?)
  /// "Sign in again?" naming why the saved sign-in stopped working.
  case reauthenticate(server: ServerIdentity, cause: ReauthCause, option: SignInOption)
  /// Databricks workspace OAuth; `isSigningIn` while the browser is open.
  case workspaceSignIn(
    server: ServerIdentity, workspaceHost: String, banner: AuthBanner?, isSigningIn: Bool)
  /// "Signing in..." with Cancel, while a browser sign-in runs.
  case signingIn(server: ServerIdentity, option: SignInOption?)
  /// A browser-ticket sign-in waiting for approval.
  case awaitingBrowserApproval(server: ServerIdentity, approval: BrowserApproval)
  /// Confirming identity with the credential.
  case connecting(server: ServerIdentity)
  /// The server signs in a way this app cannot; offers the web app instead.
  case unsupported(server: ServerIdentity, mode: SignInMode)
  /// Connected.
  case signedIn(account: SignedInAccount)

  /// Maps `state` onto a screen.
  /// - Parameter state: The view state.
  public init(state: AuthViewState) {
    let noticeBanner = state.notice.map(AuthBanner.notice)
    switch state.phase {
    case .disconnected:
      self = .serverPicker(banner: noticeBanner)
    case .discovering(let serverUrl):
      self = .discovering(serverUrl: serverUrl)
    case .signInRequired(let baseUrl, let serverName, let mode, let methods, let reason):
      let server = state.identity(baseUrl: baseUrl, serverName: serverName, mode: mode)
      self = Self.signIn(
        server: server, mode: mode, methods: methods, reason: reason, notice: noticeBanner)
    case .signingIn(let baseUrl, let method):
      self = Self.signingIn(server: state.identity(baseUrl: baseUrl), method: method)
    case .awaitingBrowserLogin(let baseUrl, let login):
      self = .awaitingBrowserApproval(server: state.identity(baseUrl: baseUrl), approval: login)
    case .connecting(let baseUrl):
      self = .connecting(server: state.identity(baseUrl: baseUrl))
    case .connected(let account):
      self = .signedIn(account: account)
    case .failed(_, let error):
      self = .serverPicker(banner: .error(error))
    }
  }

  private static func signIn(
    server: ServerIdentity, mode: SignInMode, methods: [SignInOption], reason: SignInError?,
    notice: AuthBanner?
  ) -> Self {
    let banner = reason.map(AuthBanner.error) ?? notice
    guard let primary = methods.first else {
      if mode == .localSingleUser {
        // A loopback server that still wants a sign-in is a connection problem, not a mode.
        return .serverPicker(banner: banner)
      }
      return .unsupported(server: server, mode: mode)
    }
    switch primary {
    case .password:
      return .password(server: server, banner: banner, isSubmitting: false)
    case .databricksWorkspace(let host):
      if let cause = reauthCause(reason) {
        return .reauthenticate(server: server, cause: cause, option: primary)
      }
      return .workspaceSignIn(
        server: server, workspaceHost: host, banner: banner, isSigningIn: false)
    case .browser, .loopbackBrowser, .browserTicket:
      if let cause = reauthCause(reason) {
        return .reauthenticate(server: server, cause: cause, option: primary)
      }
      return .browserSignIn(
        server: server, option: primary, alternatives: Array(methods.dropFirst()), banner: banner)
    }
  }

  /// A password sign-in keeps its form on screen; a browser sign-in shows "Signing in...".
  private static func signingIn(server: ServerIdentity, method: SignInOption?) -> Self {
    switch method {
    case .password:
      .password(server: server, banner: nil, isSubmitting: true)
    case .databricksWorkspace(let host):
      .workspaceSignIn(server: server, workspaceHost: host, banner: nil, isSigningIn: true)
    case .browser, .loopbackBrowser, .browserTicket, nil:
      .signingIn(server: server, option: method)
    }
  }

  /// A saved browser sign-in that stopped working asks "Sign in again?"; a refusal, a network
  /// failure or anything else shows on the sign-in screen instead.
  private static func reauthCause(_ reason: SignInError?) -> ReauthCause? {
    guard let reason, let failure = reason.failure, failure.asksToSignInAgain else { return nil }
    return ReauthCause(failure: failure, message: reason.message)
  }

  /// The server the screen is about, when it is about one.
  public var server: ServerIdentity? {
    switch self {
    case .serverPicker, .discovering: nil
    case .password(let server, _, _), .browserSignIn(let server, _, _, _),
      .reauthenticate(let server, _, _), .workspaceSignIn(let server, _, _, _),
      .signingIn(let server, _), .awaitingBrowserApproval(let server, _),
      .connecting(let server), .unsupported(let server, _):
      server
    case .signedIn(let account): account.server
    }
  }

  /// Whether Cancel stops work in flight (rather than leaving a form).
  public var isBusy: Bool {
    switch self {
    case .discovering, .signingIn, .awaitingBrowserApproval, .connecting: true
    case .password(_, _, let isSubmitting): isSubmitting
    case .workspaceSignIn(_, _, _, let isSigningIn): isSigningIn
    case .serverPicker, .browserSignIn, .reauthenticate, .unsupported, .signedIn: false
    }
  }
}
