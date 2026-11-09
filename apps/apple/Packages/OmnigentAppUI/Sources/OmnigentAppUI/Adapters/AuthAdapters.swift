import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentStores

// The sign-in UI mirrors the core's auth records case for case (see `SignInPhase`), so these
// are one switch each.

nonisolated extension SignInPhase {
  /// The phase for `phase`.
  /// - Parameters:
  ///   - phase: The core's phase.
  ///   - method: The sign-in this app started, so a password sign-in keeps its form on screen.
  init(_ phase: ConnectionPhase, method: SignInOption?) {
    switch phase {
    case .disconnected:
      self = .disconnected
    case .discovering(let serverUrl):
      self = .discovering(serverUrl: serverUrl)
    case .signInRequired(let baseUrl, let serverName, let mode, let methods, let reason):
      self = .signInRequired(
        baseUrl: baseUrl, serverName: serverName, mode: SignInMode(mode),
        methods: methods.map(SignInOption.init), reason: reason.map(SignInError.init))
    case .signingIn(let baseUrl):
      self = .signingIn(baseUrl: baseUrl, method: method)
    case .awaitingBrowserLogin(let baseUrl, let login):
      self = .awaitingBrowserLogin(baseUrl: baseUrl, login: BrowserApproval(login))
    case .connecting(let baseUrl):
      self = .connecting(baseUrl: baseUrl)
    case .connected(let server):
      self = .connected(server: SignedInAccount(server))
    case .failed(let serverUrl, let error):
      self = .failed(serverUrl: serverUrl, error: SignInError(error))
    }
  }
}

nonisolated extension SignInMode {
  init(_ mode: AuthenticationMode) {
    switch mode {
    case .localSingleUser: self = .localSingleUser
    case .accounts: self = .accounts
    case .oidc: self = .oidc
    case .proxy: self = .proxy
    case .unsupported(let mode): self = .unsupported(mode: mode)
    }
  }
}

nonisolated extension SignInOption {
  init(_ method: SignInMethod) {
    switch method {
    case .password: self = .password
    case .browser(let redirectUri): self = .browser(redirectUri: redirectUri)
    case .loopbackBrowser(let path): self = .loopbackBrowser(path: path)
    case .browserTicket: self = .browserTicket
    case .databricksWorkspace(let workspaceHost, _, _, _):
      self = .databricksWorkspace(workspaceHost: workspaceHost)
    }
  }
}

nonisolated extension SignInFailure {
  init(_ failure: AuthFailure) {
    switch failure {
    case .expired: self = .expired
    case .endedByServer: self = .endedByServer
    case .signInRequired: self = .signInRequired
    case .refused(let reason): self = .refused(reason: reason)
    case .transport: self = .transport
    case .failed: self = .failed
    }
  }
}

nonisolated extension SignInError {
  /// The UI's view of a core failure: the variant, the auth failure and the core's message.
  /// - Parameter error: The core error.
  init(_ error: CoreError) {
    let category: Category
    var failure: SignInFailure?
    var serverReason: String?
    switch error {
    case .InvalidUrl: category = .invalidUrl
    case .Transport: category = .transport
    case .HttpStatus(let status, _): category = .httpStatus(status: status)
    case .Decode: category = .decode
    case .Auth(_, let authFailure, _, let detail):
      category = .auth
      failure = SignInFailure(authFailure)
      serverReason = detail
    case .Oidc(_, let authFailure, _):
      category = .oidc
      failure = SignInFailure(authFailure)
    case .SecureStore: category = .secureStore
    default: category = .other
    }
    self.init(
      category: category, failure: failure, message: error.message, serverReason: serverReason)
  }
}

nonisolated extension SignedInAccount {
  init(_ server: ConnectedServer) {
    self.init(
      baseUrl: server.baseUrl, serverName: server.serverName, userId: server.userId,
      accountId: server.accountId, mode: SignInMode(server.mode))
  }
}

nonisolated extension BrowserApproval {
  init(_ login: BrowserLoginInfo) {
    self.init(loginUrl: login.loginUrl, userCode: login.userCode, expiresAtMs: login.expiresAtMs)
  }
}
