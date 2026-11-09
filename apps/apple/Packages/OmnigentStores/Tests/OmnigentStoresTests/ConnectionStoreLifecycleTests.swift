import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("Connecting and signing in", .timeLimit(.minutes(1)))
struct ConnectionStoreLifecycleTests {
  private let address = "http://127.0.0.1:6767"
  private let manifestPath = "/.well-known/omnigent.json"

  /// An accounts server with no administrator yet.
  private func accountsServer(needsSetup: Bool = true) -> RouteServer {
    let server = RouteServer()
    server.route(manifestPath, .json(#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#))
    server.route(
      "/v1/info",
      .json(#"{"single_user":false,"accounts_enabled":true,"needs_setup":\#(needsSetup)}"#))
    return server
  }

  private func tokenResponse() -> HttpResponse {
    .json(#"{"token":"tok-admin","expires_in":3600,"user":{"id":"admin"}}"#)
  }

  @Test("Discovery trims the address and reports each state")
  func discovery() async throws {
    let store = try disconnectedStore(RouteServer())
    #expect(store.state.serverURL == nil)
    #expect(!store.isConnected)
    #expect(store.discovery == nil)
    await store.discover(serverURL: "  \(address)\n")
    #expect(store.isConnected)
    #expect(store.state.serverURL == store.discovery?.baseUrl)
    #expect(store.errorMessage == nil)
    #expect(!store.isLoading)
  }

  @Test("A failed discovery keeps the address and the reason, and doesn't connect")
  func failedDiscovery() async throws {
    let server = RouteServer()
    server.fail(manifestPath)
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    #expect(store.errorMessage != nil)
    #expect(store.state.serverURL == address)
    #expect(!store.isConnected)
    #expect(!store.isSignedIn)
    #expect(store.connectedServer == nil)
    #expect(server.requests(to: "/v1/me").isEmpty)
  }

  @Test("While discovery runs the store reads loading; a newer request drops the older answer")
  func discoverySupersede() async throws {
    let server = RouteServer()
    let gate = server.hold(manifestPath)
    let store = try disconnectedStore(server)
    let older = Task { await store.discover(serverURL: address) }
    try await eventually("discovery to start") { gate.arrivals == 1 }
    #expect(store.isLoading)
    #expect(store.state.serverURL == address)
    store.reset()
    #expect(store.state == .idle)
    gate.release()
    await older.value
    #expect(store.state == .idle, "the abandoned answer doesn't come back")
  }

  @Test("A refused connection is an issue the user can dismiss")
  func connectFailure() async throws {
    let server = RouteServer()
    server.dropConnection("/v1/info")
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    #expect(!store.isSignedIn)
    #expect(store.issues.count == 1, "\(store.issues)")
    #expect(store.issues.first?.scope == .connection)
    store.dismissIssues()
    #expect(store.issues.isEmpty)
  }

  @Test("Issues keep the newest fifty, with ids that never repeat")
  func issueCap() throws {
    let store = try disconnectedStore(RouteServer())
    for index in 0..<60 {
      store.record(scope: .connection, .InvalidState(message: "\(index)"))
    }
    #expect(store.issues.count == 50)
    #expect(store.issues.first?.error.message == "10")
    #expect(store.issues.last?.error.message == "59")
    #expect(Set(store.issues.map(\.id)).count == 50)
  }

  @Test("The first administrator signs in by creating the account")
  func firstAdministrator() async throws {
    let server = accountsServer()
    server.route("/auth/setup", tokenResponse())
    server.route("/v1/me", .json(#"{"user_id":"admin"}"#))
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    let created = await store.createAccount(invite: nil, username: "admin", password: "pw")
    #expect(created?.userId == "admin")
    #expect(server.requests(to: "/auth/setup", method: "POST").count == 1)
    #expect(store.issues.isEmpty, "\(store.issues)")
  }

  @Test("An invited account registers; the server's refusal becomes an issue")
  func invitedAccount() async throws {
    let server = accountsServer(needsSetup: false)
    server.route("/auth/register", .json(#"{"error":"invite invalid or expired"}"#, status: 400))
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    let refused = await store.createAccount(invite: "tok", username: "bob", password: "pw")
    #expect(refused == nil)
    #expect(store.issues.last?.scope == .connection)
    let body = try server.body(of: try #require(server.requests(to: "/auth/register").first))
    #expect(body["invite"] as? String == "tok")

    server.route("/auth/register", tokenResponse())
    server.route("/v1/me", .json(#"{"user_id":"admin"}"#))
    let accepted = await store.createAccount(invite: "tok", username: "bob", password: "pw")
    #expect(accepted?.userId == "admin")
  }

  @Test("A wrong password records the failure and leaves the user signed out")
  func passwordSignIn() async throws {
    let server = accountsServer(needsSetup: false)
    server.route("/auth/login", .json(#"{"error":"bad credentials"}"#, status: 401))
    let store = try disconnectedStore(server)
    await store.connect(serverURL: address)
    #expect(await store.signIn(username: "bob", password: "wrong") == nil)
    #expect(store.issues.last?.scope == .connection)
    #expect(!store.isSignedIn)

    server.route("/auth/login", tokenResponse())
    server.route("/v1/me", .json(#"{"user_id":"admin"}"#))
    #expect(await store.signIn(username: "bob", password: "right")?.userId == "admin")
    try await eventually("the signed-in phase") { store.isSignedIn }
  }

  @Test("Signing out leaves the signed-in state")
  func signingOut() async throws {
    let store = try await connectedStore(RouteServer())
    await store.signOut()
    try await eventually("the sign-out") { !store.isSignedIn }
    #expect(store.connectedServer == nil)
  }

  @Test("Signing out with no server chosen is recorded")
  func signingOutOfNothing() async throws {
    let store = try disconnectedStore(RouteServer())
    await store.signOut()
    #expect(store.issues.last?.scope == .connection)
  }

  @Test("Sign-ins a server doesn't offer are recorded rather than presented")
  func unofferedSignIns() async throws {
    let store = try await connectedStore(RouteServer())
    store.dismissIssues()
    #expect(store.beginBrowserSignIn(redirectURI: "ai.omnigent:/cb") == nil)
    #expect(store.issues.count == 1)
    await store.beginBrowserTicketSignIn()
    #expect(store.browserLogin == nil)
    #expect(store.issues.count == 2)
    #expect(store.beginDatabricksSignIn() == nil)
    #expect(store.issues.count == 3)
    #expect(store.databricksChallenge == nil)
  }

  @Test("Finishing a sign-in nobody started is recorded, not trapped")
  func unknownSignInAttempts() async throws {
    let store = try await connectedStore(RouteServer())
    store.dismissIssues()
    let callback = try #require(URL(string: "ai.omnigent:/cb?code=1"))
    let oidc = OidcChallenge(
      attemptId: 404, authorizeUrl: "https://example.com", callbackScheme: "ai.omnigent",
      redirectUri: "ai.omnigent:/cb")
    #expect(await store.completeBrowserSignIn(oidc, callbackURL: callback) == nil)
    #expect(store.issues.count == 1)
    store.cancelBrowserSignIn(oidc)
  }

  @Test("A session with nothing unread is seen without asking the server")
  func markSeenNothingUnread() async throws {
    let server = RouteServer()
    let store = try await connectedStore(server)
    let writes = server.requests(method: "POST").count + server.requests(method: "PATCH").count
    #expect(await store.markSeen("conv_unknown"))
    #expect(
      server.requests(method: "POST").count + server.requests(method: "PATCH").count == writes)
    #expect(store.issues.isEmpty)
  }

  @Test("Opening a conversation twice shares one store; closing drops its stores")
  func conversationLifetime() async throws {
    let store = try await connectedStore(RouteServer())
    let first = try #require(store.conversation("conv_a"))
    #expect(store.conversation("conv_a") === first)
    let workspace = try #require(store.workspace("conv_a"))
    #expect(store.workspace("conv_a") === workspace)
    #expect(store.workspace("conv_a", environmentID: "other") !== workspace)
    let terminals = try #require(store.terminals("conv_a"))
    #expect(store.terminals("conv_a") === terminals)

    store.closeConversation("conv_a")
    #expect(store.conversations["conv_a"] == nil)
    #expect(store.workspaceStores["conv_a"] == nil)
    #expect(store.terminalStores["conv_a"] == nil)
    #expect(store.conversation("conv_a") !== first)
  }

  @Test("The form and page stores come from one core")
  func storeFactories() async throws {
    let store = try await connectedStore(RouteServer())
    let creation = try #require(store.creation())
    #expect(store.creation() === creation)
    #expect(store.share(sessionID: "conv_a") != nil)
    #expect(store.serverSettings() != nil)
    store.refreshSessions()
    store.foreground()
    store.setView(sessionID: "conv_a", focused: true)
    store.setView(sessionID: nil, focused: false)
    store.disconnect()
    try await eventually("the disconnect") { !store.isSignedIn }
  }

  @Test("Offered pages that can't be read are recorded")
  func offeredPages() async throws {
    let store = try disconnectedStore(RouteServer())
    await store.loadOfferedPages()
    #expect(store.issues.first?.scope == .connection, "no server is connected yet")
  }

  @Test("Every failure describes itself for display")
  func errorText() {
    #expect(ConnectionStore.describe(CoreError.InvalidState(message: "nope")) == "nope")
    struct Unexpected: Error {}
    #expect(ConnectionStore.describe(Unexpected()).contains("Unexpected"))
  }
}
