import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import Testing

@testable import OmnigentAppUI

/// Sign-in through the sheet: a registered scheme's OIDC redirect, and a Databricks HTTPS callback.
@MainActor
@Suite("Sign-in sheet", .serialized, .timeLimit(.minutes(1)))
struct SignInSheetTests {
  private final class Asked {
    var pages: [(URL, WebAuthenticationCallback)] = []
  }

  private func oidcServer() -> AppServer {
    let server = AppServer()
    server.route("/.well-known/omnigent.json", .json(ManifestFixtures.oidc))
    server.route("/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/v1/me", .json(#"{"detail":"sign in"}"#, status: 401))
    return server
  }

  /// A sheet that runs `answer` for the page it was given.
  private func sheet(
    _ answer:
      @escaping @MainActor (URL, WebAuthenticationCallback) throws(WebAuthenticationError)
      -> URL
  ) -> SignInController.AuthenticateInSheet {
    { url, callback throws(WebAuthenticationError) in try answer(url, callback) }
  }

  private func controller(
    _ server: AppServer, databricks: DatabricksOAuthSettings? = nil,
    sheet: @escaping SignInController.AuthenticateInSheet
  ) throws -> SignInController {
    let core = try ClientCore(
      http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TestScheduler(sleepScale: 0.01),
      secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
      config: HostConfig(
        urlPolicy: .development, oidcRedirect: .none, databricks: databricks))
    let controller = SignInController(
      store: ConnectionStore(core: core), opener: ExternalURLOpener { _ in true },
      defaults: try scratchDefaults())
    controller.authenticateInSheet = sheet
    return controller
  }

  private func reason(_ controller: SignInController) -> String? {
    switch controller.state.phase {
    case .signInRequired(_, _, _, _, let reason): reason?.message
    case .failed(_, let error): error.message
    default: nil
    }
  }

  private let redirect = "ai.omnigent.ios:/oauth/callback"

  @Test("The page opens in the sheet, for the registered scheme")
  func theSheetOpens() async throws {
    let asked = Asked()
    let controller = try controller(oidcServer()) { url, callback throws(WebAuthenticationError) in
      asked.pages.append((url, callback))
      throw .cancelled
    }
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.browser(redirectUri: redirect))
    try await eventually("the sheet") { !asked.pages.isEmpty }
    #expect(asked.pages.first?.1 == .customScheme("ai.omnigent.ios"))
    try await eventually("the notice") { controller.state.notice != nil }
    #expect(controller.state.notice == "Sign-in was cancelled.")
    #expect(reason(controller) == nil)
  }

  @Test("A sheet that fails shows why, and an answer that isn't right shows the server's reason")
  func aFailedSheet() async throws {
    let controller = try controller(oidcServer()) { _, _ throws(WebAuthenticationError) in
      throw .failed(message: "No browser engine")
    }
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.browser(redirectUri: redirect))
    try await eventually("the failure") { reason(controller) == "No browser engine" }

    let answered = try self.controller(oidcServer()) { _, _ throws(WebAuthenticationError) in
      guard let url = URL(string: "ai.omnigent.ios:/oauth/callback?code=abc&state=wrong") else {
        throw .cancelled
      }
      return url
    }
    await answered.connectNow("http://127.0.0.1:6767")
    answered.actions.startBrowserSignIn(.browser(redirectUri: redirect))
    try await eventually("the refusal") { reason(answered) != nil }
    #expect(answered.state.notice == nil)
  }

  @Test("A redirect the server's sign-in can't use says why and shows no sheet")
  func aRefusedChallenge() async throws {
    let asked = Asked()
    let controller = try controller(oidcServer()) { url, callback throws(WebAuthenticationError) in
      asked.pages.append((url, callback))
      throw .cancelled
    }
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.browser(redirectUri: "not a redirect"))
    try await eventually("the failure") { reason(controller) != nil }
    #expect(asked.pages.isEmpty)
  }

  @Test("Retry connects to the last server again, and does nothing before there was one")
  func retrying() async throws {
    let server = oidcServer()
    let controller = try controller(server) { _, _ throws(WebAuthenticationError) in
      throw .cancelled
    }
    controller.actions.retry()
    #expect(server.requests("GET", "/.well-known/omnigent.json").isEmpty)
    await controller.connectNow("http://127.0.0.1:6767")
    let before = server.requests("GET", "/.well-known/omnigent.json").count
    controller.actions.retry()
    try await eventually("the second connect") {
      server.requests("GET", "/.well-known/omnigent.json").count > before
    }
  }

  @Test("A sign-in option the browser can't run says to use the form")
  func thePasswordOption() async throws {
    let controller = try controller(oidcServer()) { _, _ throws(WebAuthenticationError) in
      throw .cancelled
    }
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.password)
    try await eventually("the message") { reason(controller) != nil }
    #expect(reason(controller) == "Use the password form to sign in.")
  }

  private let workspaceURL = "https://dbc-1.cloud.databricks.com/?o=42"
  private let httpsSettings = DatabricksOAuthSettings(
    clientId: "omnigent", redirectUrl: "https://app.example/oauth/databricks")

  private func databricksServer() -> AppServer {
    let server = AppServer()
    server.route(
      "/oidc/.well-known/openid-configuration",
      .json(
        #"{"issuer":"https://dbc-1.cloud.databricks.com/oidc","token_endpoint":"https://dbc-1.cloud.databricks.com/oidc/v1/token"}"#
      ))
    server.route(
      "/oidc/v1/token",
      .json(
        #"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","expires_in":3600}"#
      ))
    server.route(
      "/api/2.0/omnigent/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/api/2.0/omnigent/v1/me", .json(#"{"user_id":"ada"}"#))
    return server
  }

  private func startDatabricks(_ controller: SignInController) async throws {
    await controller.connectNow(workspaceURL)
    try await eventually("the workspace sign-in") {
      if case .signInRequired = controller.store.phase { true } else { false }
    }
    controller.actions.startBrowserSignIn(
      .databricksWorkspace(workspaceHost: "dbc-1.cloud.databricks.com"))
  }

  @Test("A workspace without a loopback client signs in through the sheet's HTTPS callback")
  func databricksThroughTheSheet() async throws {
    let asked = Asked()
    let answer: @MainActor (URL, WebAuthenticationCallback) throws(WebAuthenticationError) -> URL
    answer = { url, callback throws(WebAuthenticationError) in
      asked.pages.append((url, callback))
      let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "state" }?.value
      let page = "https://app.example/oauth/databricks?code=c&state=\(state ?? "")"
      guard let answer = URL(string: page) else { throw .cancelled }
      return answer
    }
    let controller = try controller(
      databricksServer(), databricks: httpsSettings, sheet: sheet(answer))
    try await startDatabricks(controller)
    try await eventually("signing in") { controller.store.isSignedIn }
    #expect(asked.pages.first?.0.path() == "/oidc/v1/authorize")
    #expect(asked.pages.first?.1 == .https(host: "app.example", path: "/oauth/databricks"))
    #expect(controller.store.connectedServer?.userId == "ada")
    #expect(reason(controller) == nil)
  }

  @Test("Closing the workspace's sheet is a note; a sheet failure says why")
  func databricksSheetEnds() async throws {
    let refuse: SignInController.AuthenticateInSheet = { _, _ throws(WebAuthenticationError) in
      throw .cancelled
    }
    let closed = try controller(databricksServer(), databricks: httpsSettings, sheet: refuse)
    try await startDatabricks(closed)
    try await eventually("the note") { closed.state.notice != nil }
    #expect(closed.state.notice == "Sign-in was cancelled.")

    let fail: SignInController.AuthenticateInSheet = { _, _ throws(WebAuthenticationError) in
      throw .failed(message: "No browser engine")
    }
    let failed = try controller(databricksServer(), databricks: httpsSettings, sheet: fail)
    try await startDatabricks(failed)
    try await eventually("the failure") { reason(failed) == "No browser engine" }
  }

  @Test("A server that isn't a workspace says so instead of opening a sheet")
  func databricksNotOffered() async throws {
    let asked = Asked()
    let controller = try controller(oidcServer()) { url, callback throws(WebAuthenticationError) in
      asked.pages.append((url, callback))
      throw .cancelled
    }
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.databricksWorkspace(workspaceHost: "dbc.example"))
    try await eventually("the failure") { reason(controller) != nil }
    #expect(asked.pages.isEmpty)
  }
}
