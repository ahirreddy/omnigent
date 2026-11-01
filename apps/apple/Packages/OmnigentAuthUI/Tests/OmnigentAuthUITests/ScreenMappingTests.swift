import Foundation
import Testing

@testable import OmnigentAuthUI

private let base = "https://omnigent.example.com"
private let browserMethods: [SignInOption] = [
  .loopbackBrowser(path: "/oauth/callback"), .browserTicket,
]

private func required(
  mode: SignInMode = .oidc, methods: [SignInOption] = browserMethods, reason: SignInError? = nil,
  serverName: String? = "Example"
) -> SignInPhase {
  .signInRequired(
    baseUrl: base, serverName: serverName, mode: mode, methods: methods, reason: reason)
}

private func oidcError(_ failure: SignInFailure, _ message: String = "message") -> SignInError {
  SignInError(category: .oidc, failure: failure, message: message)
}

struct ScreenMappingTests {
  @Test func disconnectedShowsThePickerWithAnyNotice() {
    #expect(AuthViewState().screen == .serverPicker(banner: nil))
    let state = AuthViewState(notice: "You\u{2019}re signed out of host.")
    #expect(state.screen == .serverPicker(banner: .notice("You\u{2019}re signed out of host.")))
  }

  @Test func failureShowsThePickerWithTheErrorAndKeepsTheURL() {
    let error = SignInError(category: .transport, message: "offline")
    let state = AuthViewState(
      phase: .failed(serverUrl: "omnigent.example.com", error: error), lastServerUrl: "older")
    #expect(state.screen == .serverPicker(banner: .error(error)))
    #expect(state.prefillServerUrl == "omnigent.example.com")
  }

  @Test func cancelKeepsTheLastURL() {
    let state = AuthViewState(phase: .disconnected, lastServerUrl: base)
    #expect(state.prefillServerUrl == base)
  }

  @Test func discoveringAndConnecting() {
    #expect(
      AuthViewState(phase: .discovering(serverUrl: "x")).screen == .discovering(serverUrl: "x"))
    let connecting = AuthViewState(phase: .connecting(baseUrl: base)).screen
    #expect(connecting == .connecting(server: ServerIdentity(baseUrl: base)))
    #expect(connecting.isBusy)
  }

  @Test func accountsModeShowsThePasswordForm() {
    let screen = AuthViewState(phase: required(mode: .accounts, methods: [.password])).screen
    guard case .password(let server, let banner, let isSubmitting) = screen else {
      Issue.record("expected the password form, got \(screen)")
      return
    }
    #expect(server.mode == .accounts)
    #expect(server.serverName == "Example")
    #expect(banner == nil)
    #expect(!isSubmitting)
  }

  @Test func aRejectedPasswordStaysOnTheFormWithTheReason() {
    let error = SignInError(
      category: .auth, failure: .signInRequired, message: "Sign in again.",
      serverReason: "invalid username or password")
    let screen = AuthViewState(
      phase: required(mode: .accounts, methods: [.password], reason: error)
    ).screen
    #expect(
      screen
        == .password(
          server: ServerIdentity(baseUrl: base, serverName: "Example", mode: .accounts),
          banner: .error(error), isSubmitting: false))
    #expect(error.refusalReason == "invalid username or password")
  }

  @Test func aPasswordSignInInFlightKeepsTheForm() {
    let screen = AuthViewState(phase: .signingIn(baseUrl: base, method: .password)).screen
    #expect(
      screen == .password(server: ServerIdentity(baseUrl: base), banner: nil, isSubmitting: true))
    #expect(screen.isBusy)
  }

  @Test func oidcOffersTheBestBrowserOptionAndTheRest() {
    let screen = AuthViewState(phase: required()).screen
    #expect(
      screen
        == .browserSignIn(
          server: ServerIdentity(baseUrl: base, serverName: "Example", mode: .oidc),
          option: .loopbackBrowser(path: "/oauth/callback"), alternatives: [.browserTicket],
          banner: nil))
    #expect(!screen.isBusy)
  }

  @Test(arguments: [SignInFailure.expired, .endedByServer, .signInRequired])
  func aSavedSignInThatStoppedWorkingAsksToSignInAgain(failure: SignInFailure) {
    let screen = AuthViewState(phase: required(reason: oidcError(failure, "why"))).screen
    #expect(
      screen
        == .reauthenticate(
          server: ServerIdentity(baseUrl: base, serverName: "Example", mode: .oidc),
          cause: ReauthCause(failure: failure, message: "why"),
          option: .loopbackBrowser(path: "/oauth/callback")))
  }

  @Test func aRefusalStaysOnSignInWithTheReasonVerbatim() {
    let reason = "Sign-ins from <b>gmail.com</b> are not allowed."
    let error = oidcError(.refused(reason: reason), reason)
    let screen = AuthViewState(phase: required(reason: error)).screen
    guard case .browserSignIn(_, _, _, .error(let shown)) = screen else {
      Issue.record("expected browser sign-in with an error, got \(screen)")
      return
    }
    #expect(shown.refusalReason == reason)
    // The message only repeats the reason, so the banner shows the reason once.
    #expect(shown.detail == nil)
    #expect(shown.title == "Sign-in refused")
  }

  @Test(arguments: [SignInFailure.transport, .failed, .refused(reason: nil)])
  func otherFailuresShowOnTheSignInScreen(failure: SignInFailure) {
    let error = oidcError(failure)
    let screen = AuthViewState(phase: required(reason: error)).screen
    guard case .browserSignIn(_, _, _, .error(let shown)) = screen else {
      Issue.record("expected browser sign-in with an error, got \(screen)")
      return
    }
    #expect(shown == error)
  }

  @Test func aReasonWinsOverANotice() {
    let error = oidcError(.failed)
    let state = AuthViewState(phase: required(reason: error), notice: "Sign-in was cancelled.")
    guard case .browserSignIn(_, _, _, let banner) = state.screen else {
      Issue.record("expected browser sign-in, got \(state.screen)")
      return
    }
    #expect(banner == .error(error))
    let cancelled = AuthViewState(phase: required(), notice: "Sign-in was cancelled.")
    guard case .browserSignIn(_, _, _, let notice) = cancelled.screen else {
      Issue.record("expected browser sign-in, got \(cancelled.screen)")
      return
    }
    #expect(notice == .notice("Sign-in was cancelled."))
  }

  @Test func browserSignInInFlightIsSigningIn() {
    let option = SignInOption.loopbackBrowser(path: "/oauth/callback")
    let screen = AuthViewState(phase: .signingIn(baseUrl: base, method: option)).screen
    #expect(screen == .signingIn(server: ServerIdentity(baseUrl: base), option: option))
    let unknown = AuthViewState(phase: .signingIn(baseUrl: base)).screen
    #expect(unknown == .signingIn(server: ServerIdentity(baseUrl: base), option: nil))
  }

  @Test func ticketAwaitsApproval() {
    let approval = BrowserApproval(loginUrl: "\(base)/auth/login?ticket=t", expiresAtMs: 1)
    let screen = AuthViewState(phase: .awaitingBrowserLogin(baseUrl: base, login: approval)).screen
    #expect(
      screen == .awaitingBrowserApproval(server: ServerIdentity(baseUrl: base), approval: approval))
  }

  @Test func databricksWorkspace() {
    let option = SignInOption.databricksWorkspace(workspaceHost: "dbc.cloud.databricks.com")
    let idle = AuthViewState(phase: required(mode: .proxy, methods: [option])).screen
    guard case .workspaceSignIn(_, "dbc.cloud.databricks.com", nil, false) = idle else {
      Issue.record("expected workspace sign-in, got \(idle)")
      return
    }
    let busy = AuthViewState(phase: .signingIn(baseUrl: base, method: option)).screen
    guard case .workspaceSignIn(_, _, _, true) = busy else {
      Issue.record("expected workspace sign-in in flight, got \(busy)")
      return
    }
    #expect(busy.isBusy)
    let expired = AuthViewState(
      phase: required(mode: .proxy, methods: [option], reason: oidcError(.expired))
    ).screen
    guard case .reauthenticate(_, _, option) = expired else {
      Issue.record("expected sign in again, got \(expired)")
      return
    }
  }

  @Test(arguments: [SignInMode.proxy, .unsupported(mode: "saml"), .oidc, .accounts])
  func noMethodsMeansUnsupported(mode: SignInMode) {
    let screen = AuthViewState(phase: required(mode: mode, methods: [])).screen
    guard case .unsupported(let server, mode) = screen else {
      Issue.record("expected unsupported, got \(screen)")
      return
    }
    #expect(server.webURL?.absoluteString == base)
  }

  @Test func aLocalServerThatWantsSignInIsAConnectionProblem() {
    let error = SignInError(category: .auth, failure: .failed, message: "x")
    let screen = AuthViewState(
      phase: required(mode: .localSingleUser, methods: [], reason: error)
    ).screen
    #expect(screen == .serverPicker(banner: .error(error)))
  }

  @Test func connectedIsSignedIn() {
    let account = SignedInAccount(
      baseUrl: base, serverName: nil, userId: "ada", accountId: "a", mode: .oidc)
    let screen = AuthViewState(phase: .connected(server: account)).screen
    #expect(screen == .signedIn(account: account))
    #expect(screen.server == account.server)
    #expect(account.canSignOut)
    let local = SignedInAccount(
      baseUrl: "http://127.0.0.1:6767", userId: "local", accountId: "l", mode: .localSingleUser)
    #expect(!local.canSignOut)
    #expect(local.userLabel == "Local user")
  }

  @Test func discoveredDetailsApplyOnlyToTheSameServer() {
    let discovered = ServerIdentity(
      baseUrl: base, serverName: "Discovered", serverVersion: "0.9.2", mode: .oidc,
      needsSetup: true)
    let same = AuthViewState(phase: .connecting(baseUrl: base), server: discovered).screen
    #expect(same.server?.serverVersion == "0.9.2")
    #expect(same.server?.needsSetup == true)
    let other = AuthViewState(
      phase: .connecting(baseUrl: "https://other.example"), server: discovered
    ).screen
    #expect(other.server?.serverVersion == nil)
    #expect(other.server?.serverName == nil)
    // The phase's own name and mode win over discovery.
    let named = AuthViewState(phase: required(serverName: "Phase"), server: discovered).screen
    #expect(named.server?.serverName == "Phase")
  }

  @Test func everySampleMapsToItsIntendedScreen() throws {
    let expected: [String: String] = [
      "picker": "serverPicker", "picker-signed-out": "serverPicker",
      "picker-unreachable": "serverPicker", "picker-invalid-url": "serverPicker",
      "discovering": "discovering", "password": "password", "password-error": "password",
      "password-submitting": "password", "browser": "browserSignIn",
      "browser-refused": "browserSignIn", "signing-in": "signingIn",
      "ticket": "awaitingBrowserApproval", "reauth-expired": "reauthenticate",
      "reauth-ended": "reauthenticate", "workspace": "workspaceSignIn",
      "workspace-signing-in": "workspaceSignIn", "unsupported": "unsupported",
      "proxy": "unsupported", "connecting": "connecting", "signed-in": "signedIn",
    ]
    #expect(Set(AuthSamples.all.map(\.id)) == Set(expected.keys))
    for sample in AuthSamples.all {
      let screen = sample.state.screen
      let name = String(describing: screen).prefix { $0 != "(" }
      #expect(String(name) == expected[sample.id], "\(sample.id) mapped to \(screen)")
    }
  }
}

struct SignInErrorTests {
  @Test func retryableForNetworkAndStatus() {
    #expect(SignInError(category: .transport, message: "").isRetryable)
    #expect(SignInError(category: .httpStatus(status: 502), message: "").isRetryable)
    #expect(SignInError(category: .oidc, failure: .transport, message: "").isRetryable)
    #expect(!SignInError(category: .invalidUrl, message: "").isRetryable)
    #expect(!SignInError(category: .oidc, failure: .refused(reason: nil), message: "").isRetryable)
  }

  @Test func blankReasonsAreNone() {
    let blank = SignInError(category: .oidc, failure: .refused(reason: "  "), message: "m")
    #expect(blank.refusalReason == nil)
    let fallback = SignInError(
      category: .oidc, failure: .refused(reason: nil), message: "m", serverReason: "domain")
    #expect(fallback.refusalReason == "domain")
  }

  @Test func titlesNameTheCause() {
    #expect(SignInError(category: .oidc, failure: .expired, message: "").title == "Sign-in expired")
    #expect(
      SignInError(category: .httpStatus(status: 503), message: "").title
        == "The server returned HTTP 503")
    #expect(SignInError(category: .invalidUrl, message: "").title == "Check the server URL")
  }

  @Test func reauthExplanationFallsBackToTheHeadline() {
    #expect(ReauthCause(failure: .expired, message: " ").explanation == "Your sign-in expired.")
    #expect(
      ReauthCause(failure: .endedByServer, message: "host ended it.").explanation
        == "host ended it.")
  }

  @Test func hostLabels() {
    #expect(ServerIdentity.hostLabel("https://h.example:8443/api") == "h.example:8443")
    #expect(ServerIdentity.hostLabel("http://127.0.0.1:6767") == "127.0.0.1:6767")
    #expect(ServerIdentity.hostLabel("not a url") == "not a url")
    #expect(ServerIdentity(baseUrl: base, serverName: "  ").displayName == "omnigent.example.com")
  }
}
