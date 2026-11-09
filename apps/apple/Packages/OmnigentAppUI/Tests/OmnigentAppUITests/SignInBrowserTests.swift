import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import Testing

@testable import OmnigentAppUI

/// The browser half of sign-in: the page opens outside the app, its answer comes back to a
/// listener on this machine, and each way that goes wrong says so.
@MainActor
@Suite("Browser sign-in", .serialized, .timeLimit(.minutes(1)))
struct SignInBrowserTests {
  private final class Browser: @unchecked Sendable {
    var opened: [URL] = []
    var opens = true
  }

  private func oidcServer() -> AppServer {
    let server = AppServer()
    server.route("/.well-known/omnigent.json", .json(ManifestFixtures.oidc))
    server.route("/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/v1/me", .json(#"{"detail":"sign in"}"#, status: 401))
    return server
  }

  private func controller(
    _ server: AppServer, keychain: InMemorySecureStore = InMemorySecureStore()
  ) throws -> (SignInController, Browser) {
    let core = try ClientCore(
      http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TestScheduler(sleepScale: 0.01), secureStore: keychain,
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let browser = Browser()
    let opener = ExternalURLOpener { url in
      browser.opened.append(url)
      return browser.opens
    }
    let controller = SignInController(
      store: ConnectionStore(core: core), opener: opener, defaults: try scratchDefaults())
    return (controller, browser)
  }

  private func reason(_ controller: SignInController) -> String? {
    switch controller.state.phase {
    case .signInRequired(_, _, _, _, let reason): reason?.message
    case .failed(_, let error): error.message
    default: nil
    }
  }

  /// Connects and starts the loopback flow, returning the page it asked the browser to open.
  private func startLoopback(
    _ server: AppServer
  ) async throws -> (SignInController, URLComponents) {
    let (controller, browser) = try controller(server)
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.loopbackBrowser(path: "/callback"))
    try await eventually("the page") { !browser.opened.isEmpty }
    let page = try #require(browser.opened.first)
    return (controller, try #require(URLComponents(url: page, resolvingAgainstBaseURL: false)))
  }

  /// What the browser does at the end: goes to the listener with the server's answer.
  private func answer(_ page: URLComponents, code: String? = "abc", state: String? = nil)
    async throws
  {
    let query = page.queryItems ?? []
    let redirect = try #require(query.first { $0.name == "native_redirect_uri" }?.value)
    var callback = try #require(URLComponents(string: redirect))
    callback.queryItems = [
      URLQueryItem(name: "code", value: code),
      URLQueryItem(name: "state", value: state ?? query.first { $0.name == "native_state" }?.value),
    ].filter { $0.value != nil }
    _ = try await URLSession.shared.data(from: try #require(callback.url))
  }

  @Test("The page opens in the browser and its answer signs in")
  func loopbackSignsIn() async throws {
    let server = oidcServer()
    server.route(
      "/auth/native-token", .json(#"{"token":"session-1","refresh_token":"r1","user_id":"u1"}"#))
    let (controller, page) = try await startLoopback(server)
    if case .signingIn(_, let method) = controller.state.phase {
      #expect(method == .loopbackBrowser(path: "/callback"), "the screen says which sign-in runs")
    } else {
      Issue.record("expected signing in, got \(controller.state.phase)")
    }
    var signedIn: [ConnectedServer] = []
    controller.onSignedIn = { signedIn.append($0) }
    server.route("/v1/me", .json(#"{"user_id":"u1"}"#))
    try await answer(page)
    try await eventually("signing in") { !signedIn.isEmpty }
    #expect(signedIn.first?.userId == "u1")
    #expect(server.requests("POST", "/auth/native-token").count == 1)
    #expect(controller.state.notice == nil)
  }

  @Test("A browser that won't open says so and leaves the sign-in choices")
  func theBrowserWontOpen() async throws {
    let (controller, browser) = try controller(oidcServer())
    browser.opens = false
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.loopbackBrowser(path: "/callback"))
    try await eventually("the failure") { reason(controller) != nil }
    #expect(
      reason(controller)?.hasPrefix("Could not open the sign-in page in your browser") == true)
  }

  @Test("Cancel stops waiting for the browser and says so")
  func cancelling() async throws {
    let (controller, _) = try await startLoopback(oidcServer())
    controller.actions.cancel()
    try await eventually("the sign-in choices") {
      if case .signInRequired = controller.state.phase { return true }
      return false
    }
    #expect(controller.state.notice == "Sign-in was cancelled.")
  }

  @Test("An answer the server refuses shows why, and sign-in can start again")
  func aRefusedAnswer() async throws {
    let server = oidcServer()
    server.route("/auth/native-token", .json(#"{"detail":"bad code"}"#, status: 400))
    let (controller, page) = try await startLoopback(server)
    try await answer(page)
    try await eventually("the refusal") { reason(controller) != nil }
    #expect(controller.state.notice == nil)
    #expect(!server.requests("POST", "/auth/native-token").isEmpty)
  }

  @Test("An answer for another sign-in is refused without asking the server")
  func aForgedAnswer() async throws {
    let server = oidcServer()
    let (controller, page) = try await startLoopback(server)
    try await answer(page, state: "someone-elses")
    try await eventually("the refusal") { reason(controller) != nil }
    #expect(server.requests("POST", "/auth/native-token").isEmpty)
  }

  @Test("The password choice points at the form")
  func passwordSaysUseTheForm() async throws {
    let (controller, _) = try controller(oidcServer())
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.password)
    try await eventually("the words") { reason(controller) != nil }
    #expect(reason(controller) == "Use the password form to sign in.")
  }

  @Test("A browser ticket opens its page, and the approved poll signs in")
  func browserTicket() async throws {
    let server = oidcServer()
    server.route(
      "/auth/cli-login", method: "POST",
      .json(
        #"{"ticket":"t1","login_url":"/auth/login?ticket=t1&reauth=1","user_code":"ABCD","expires_in":60}"#
      ))
    server.route("/auth/cli-poll", .json(#"{"token":"session-1","user_id":"u1","expires_in":60}"#))
    let (controller, browser) = try controller(server)
    var signedIn: [ConnectedServer] = []
    controller.onSignedIn = { signedIn.append($0) }
    await controller.connectNow("http://127.0.0.1:6767")
    server.route("/v1/me", .json(#"{"user_id":"u1"}"#))
    controller.actions.startBrowserSignIn(.browserTicket)
    try await eventually("signing in") { !signedIn.isEmpty }
    #expect(browser.opened.first?.query?.contains("ticket=t1") == true)
    #expect(signedIn.first?.userId == "u1")
  }

  private func ticketServer() -> AppServer {
    let server = oidcServer()
    server.route(
      "/auth/cli-login", method: "POST",
      .json(
        #"{"ticket":"t1","login_url":"/auth/login?ticket=t1&reauth=1","user_code":"ABCD","expires_in":60}"#
      ))
    server.route("/auth/cli-poll", .json("{}", status: 202))
    return server
  }

  @Test("A ticket that expires goes back to the sign-in choices and says why")
  func anExpiredTicket() async throws {
    let server = ticketServer()
    let (controller, browser) = try controller(server)
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.browserTicket)
    try await eventually("the page") { !browser.opened.isEmpty }
    server.route("/auth/cli-poll", .json(#"{"detail":"expired"}"#, status: 410))
    try await eventually("the reason") { reason(controller) != nil }
    #expect(controller.method == nil)
  }

  @Test("Cancel stops waiting on a ticket and leaves for the server picker")
  func cancellingATicket() async throws {
    let (controller, browser) = try controller(ticketServer())
    var left: [URL?] = []
    await controller.connectNow("http://127.0.0.1:6767")
    controller.onServerChange = { left.append($0) }
    controller.actions.startBrowserSignIn(.browserTicket)
    try await eventually("the page") { !browser.opened.isEmpty }
    controller.actions.cancel()
    #expect(left == [nil])
    try await eventually("the wait to end") { controller.store.phase == .disconnected }
  }

  @Test("A browser that won't open the ticket's page says so")
  func aTicketPageThatWontOpen() async throws {
    let (controller, browser) = try controller(ticketServer())
    browser.opens = false
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.browserTicket)
    try await eventually("the page") { !browser.opened.isEmpty }
    try await eventually("the failure") { controller.flowError != nil }
    #expect(controller.flowError?.message.hasPrefix("Could not open the sign-in page") == true)
  }

  @Test("A ticket the server refuses at once says why, and no page opens")
  func aRefusedTicket() async throws {
    let server = oidcServer()
    server.route("/auth/cli-login", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
    let (controller, browser) = try controller(server)
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.browserTicket)
    try await eventually("the refusal") { reason(controller) != nil }
    #expect(browser.opened.isEmpty)
  }

  @Test("Signing out says who from")
  func signingOut() async throws {
    let core = try ClientCore(
      http: AppServer().http, streams: FakeEventStreamTransport(),
      sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let controller = SignInController(
      store: ConnectionStore(core: core), opener: ExternalURLOpener { _ in true },
      defaults: try scratchDefaults())
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.signOut()
    try await eventually("the notice") { controller.state.notice != nil }
    #expect(controller.state.notice?.contains("signed out") == true)
  }
}
