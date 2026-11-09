import AppKit
import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// Each way the browser sign-in's listener and sign-in page can fail before the browser opens.
@MainActor
@Suite("Sign-in listener failures", .serialized, .timeLimit(.minutes(1)))
struct SignInListenerTests {
  private func oidcServer() -> AppServer {
    let server = AppServer()
    server.route("/.well-known/omnigent.json", .json(ManifestFixtures.oidc))
    server.route("/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/v1/me", .json(#"{"detail":"sign in"}"#, status: 401))
    return server
  }

  private func databricksServer() -> AppServer {
    let server = AppServer()
    server.route(
      "/oidc/.well-known/openid-configuration",
      .json(
        #"{"issuer":"https://dbc-1.cloud.databricks.com/oidc","token_endpoint":"https://dbc-1.cloud.databricks.com/oidc/v1/token"}"#
      ))
    return server
  }

  private func controller(
    _ server: AppServer, databricks: DatabricksOAuthSettings? = nil
  ) throws -> SignInController {
    let core = try ClientCore(
      http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TestScheduler(sleepScale: 0.01),
      secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none, databricks: databricks))
    return SignInController(
      store: ConnectionStore(core: core), opener: ExternalURLOpener { _ in true },
      defaults: try scratchDefaults())
  }

  /// A listener that was cancelled before it started, so starting it fails.
  private func spentListener() -> LoopbackRedirectListener {
    let listener = LoopbackRedirectListener()
    listener.cancel()
    return listener
  }

  private func reason(_ controller: SignInController) -> String? {
    switch controller.state.phase {
    case .signInRequired(_, _, _, _, let reason): reason?.message
    case .failed(_, let error): error.message
    default: nil
    }
  }

  private func startDatabricks(_ controller: SignInController) async throws {
    await controller.connectNow("https://dbc-1.cloud.databricks.com/?o=42")
    try await eventually("the workspace sign-in") {
      if case .signInRequired = controller.store.phase { true } else { false }
    }
    controller.actions.startBrowserSignIn(
      .databricksWorkspace(workspaceHost: "dbc-1.cloud.databricks.com"))
  }

  @Test("A listener that can't start says so, and no sign-in page opens")
  func loopbackListenerFails() async throws {
    let controller = try controller(oidcServer())
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.startBrowserSignIn(.loopbackBrowser(path: "no-leading-slash"))
    try await eventually("the failure") { reason(controller) != nil }
    #expect(reason(controller)?.hasPrefix("Could not receive the browser sign-in") == true)
    #expect(controller.method == nil)
  }

  @Test("A Databricks listener that can't start says so")
  func databricksListenerFails() async throws {
    let controller = try controller(
      databricksServer(),
      databricks: DatabricksOAuthSettings(clientId: "omnigent", redirectUrl: "http://localhost"))
    controller.makeListener = { spentListener() }
    try await startDatabricks(controller)
    try await eventually("the failure") { reason(controller) != nil }
    #expect(reason(controller)?.hasPrefix("Could not receive the browser sign-in") == true)
  }

  @Test("A Databricks challenge the server can't give says why, and stops listening")
  func databricksRefused() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let controller = SignInController(
      store: connection, opener: ExternalURLOpener { _ in true }, defaults: try scratchDefaults())
    let listener = LoopbackRedirectListener()
    _ = try await listener.start(path: "/", host: "localhost")
    #expect(controller.beginDatabricks(port: 1, listener: listener) == nil)
    #expect(controller.flowError != nil, "not a Databricks server")
    await #expect(throws: LoopbackRedirectError.cancelled) {
      try await listener.waitForCallback()
    }

    let noCore = SignInController(
      store: ConnectionStore(startupError: .InvalidState(message: "No keychain")),
      opener: ExternalURLOpener { _ in true }, defaults: try scratchDefaults())
    #expect(noCore.beginDatabricks(port: 1, listener: LoopbackRedirectListener()) == nil)
    #expect(noCore.flowError == nil, "the store already says it can't start")
  }

  @Test("A challenge whose page isn't a URL is refused with the page's address")
  func notAPage() throws {
    #expect(
      throws: WebAuthenticationError.failed(message: "The server's sign-in page is not a URL: ")
    ) {
      try SignInController.signInPage("", of: "The server's")
    }
    #expect(throws: WebAuthenticationError.self) {
      try SignInController.signInPage("http://[", of: "The workspace")
    }
    let page = try SignInController.signInPage("https://a.test/login?x=1", of: "The server's")
    #expect(page.host() == "a.test")
  }

  @Test("A listener's port is the one in its address, or a failure naming the address")
  func ports() throws {
    #expect(
      try SignInController.loopbackPort(of: #require(URL(string: "http://localhost:4242/"))) == 4242
    )
    for address in ["http://localhost/", "http://localhost:70000/"] {
      let url = try #require(URL(string: address))
      #expect(
        throws: LoopbackRedirectError.failed(
          message: "The sign-in listener has no port: \(address)")
      ) { try SignInController.loopbackPort(of: url) }
    }
  }

  @Test("Every listener failure reads as a sentence on the sign-in screen")
  func listenerErrors() {
    let words: [(LoopbackRedirectError, String)] = [
      (.failed(message: "No sockets"), "No sockets"),
      (.cancelled, "The sign-in was cancelled."),
      (.alreadyStarted, "busy"), (.notStarted, "busy"), (.alreadyWaiting, "busy"),
    ]
    for (error, expected) in words {
      let shown = SignInController.listenerError(error)
      #expect(shown.category == .oidc)
      #expect(shown.message.hasPrefix("Could not receive the browser sign-in: "))
      #expect(shown.message.contains(expected), "\(shown.message)")
    }
  }

  @Test("The system sheet says so when no window can hold it, and shows nothing")
  func systemSheetWithoutAWindow() async throws {
    try #require(NSApp?.keyWindow == nil && NSApp?.mainWindow == nil, "a sheet must not show")
    let page = try #require(URL(string: "https://a.test/login"))
    let sheet = SignInController.systemSheet()
    do {
      _ = try await sheet(page, .customScheme("ai.omnigent"))
      Issue.record("a sheet showed")
    } catch {
      #expect(error == .failed(message: "No window is available to present the sign-in sheet."))
    }
  }

  @Test("An error the core didn't make keeps its words")
  func foreignErrors() {
    struct Odd: Error {}
    #expect(thrownByCore(Odd()) == .InvalidState(message: "Odd()"))
    let core = CoreError.InvalidState(message: "Busy")
    #expect(thrownByCore(core) == core)
  }

  /// A keychain that keeps what it may and refuses what it's told to.
  private nonisolated final class RefusingKeychain: SecureStore, Sendable {
    let kept = InMemorySecureStore()
    let refusesSaving: Bool

    init(refusesSaving: Bool) { self.refusesSaving = refusesSaving }

    func get(key: SecureStoreKey) throws(SecureStoreError) -> Data? {
      try kept.get(key: key)
    }
    func set(key: SecureStoreKey, value: Data) throws(SecureStoreError) {
      if refusesSaving { throw .Unavailable(message: "Locked") }
      try kept.set(key: key, value: value)
    }
    func delete(key: SecureStoreKey) throws(SecureStoreError) {
      throw .Unavailable(message: "Locked")
    }
  }

  private func accountsController(refusesSaving: Bool) throws -> SignInController {
    let routes: [String: HttpResponse] = [
      "/.well-known/omnigent.json": .json(#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#),
      "/v1/info": .json(#"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#),
      "/auth/login": .json(#"{"token":"tok","expires_in":3600,"user":{"id":"u1"}}"#),
      "/v1/me": .json(#"{"user_id":"u1"}"#),
      "/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
    ]
    let core = try ClientCore(
      http: FakeHttpTransport(routes: routes), streams: FakeEventStreamTransport(),
      sockets: FakeWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
      secureStore: RefusingKeychain(refusesSaving: refusesSaving), entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    return SignInController(
      store: ConnectionStore(core: core), opener: ExternalURLOpener { _ in true },
      defaults: try scratchDefaults())
  }

  @Test("A sign-in the server accepted but the keychain refused shows why, not a spinner")
  func aRefusedCredential() async throws {
    let controller = try accountsController(refusesSaving: true)
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.submitCredentials(AccountCredentials(username: "ada", password: "pw"))
    try await eventually("the failure") { reason(controller) != nil }
    #expect(controller.method == nil)
  }

  @Test("Signing out with a keychain that won't forget says why")
  func aRefusedSignOut() async throws {
    let controller = try accountsController(refusesSaving: false)
    await controller.connectNow("http://127.0.0.1:6767")
    controller.actions.submitCredentials(AccountCredentials(username: "ada", password: "pw"))
    try await eventually("the sign-in") { controller.store.connectedServer != nil }
    controller.actions.signOut()
    try await eventually("the outcome") {
      controller.flowError != nil || controller.notice != nil
    }
    #expect(controller.flowError != nil)
    #expect(controller.notice == nil)
  }

  @Test("A server address the core refuses says why")
  func aRefusedAddress() async throws {
    let controller = try controller(AppServer())
    await controller.connectNow("ftp://nowhere")
    // The core's failed phase reaches the store as an event, after the connect returns.
    try await eventually("the failure") { reason(controller) != nil }
  }

  @Test("A server that can't be reached is unreachable in the list")
  func checkingAnUnreachableServer() async throws {
    let controller = try controller(AppServer())
    #expect(await controller.actions.checkServer("ftp://nowhere") == .unreachable)
    let none = SignInController(
      store: ConnectionStore(startupError: .InvalidState(message: "No keychain")),
      opener: ExternalURLOpener { _ in true }, defaults: try scratchDefaults())
    #expect(await none.actions.checkServer("https://a.test") == .unreachable)
  }

  @Test("The picker's check refuses what the core refuses, and says why")
  func validatingServers() throws {
    let accepted = try ServerURLValidator.app.normalize("http://127.0.0.1:6767").get()
    #expect(accepted.hasPrefix("http://127.0.0.1"))
    guard case .failure(let rejection) = ServerURLValidator.app.normalize("ftp://nowhere") else {
      Issue.record("ftp is accepted")
      return
    }
    #expect(!rejection.message.isEmpty)
  }
}
