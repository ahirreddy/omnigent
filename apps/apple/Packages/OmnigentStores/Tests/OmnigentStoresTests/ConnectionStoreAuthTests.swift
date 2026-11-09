import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A Databricks workspace serving Omnigent at its API mount, with its OAuth endpoints.
nonisolated private let workspaceRoutes: [String: HttpResponse] = [
  "/oidc/.well-known/openid-configuration": .json(
    #"{"issuer":"https://dbc-1.cloud.databricks.com/oidc","#
      + #""token_endpoint":"https://dbc-1.cloud.databricks.com/oidc/v1/token"}"#),
  "/oidc/v1/token": .json(
    #"{"access_token":"access-1","refresh_token":"refresh-1","token_type":"Bearer","#
      + #""expires_in":3600}"#),
  "/api/2.0/omnigent/v1/info": .json(#"{"single_user":false,"accounts_enabled":false}"#),
  "/api/2.0/omnigent/v1/me": .json(#"{"user_id":"ada"}"#),
  "/api/2.0/omnigent/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
]

/// Signing in to a Databricks workspace, and naming how a server signs in.
@MainActor
@Suite("Workspace sign-in", .timeLimit(.minutes(1)))
struct ConnectionStoreAuthTests {
  private func workspaceStore() async throws -> ConnectionStore {
    let core = try ClientCore(
      http: FakeHttpTransport(routes: workspaceRoutes), streams: FakeEventStreamTransport(),
      sockets: FakeWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
      secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
      config: HostConfig(
        urlPolicy: .development, oidcRedirect: .none,
        databricks: DatabricksOAuthSettings(clientId: "omnigent", redirectUrl: "http://localhost")))
    let store = ConnectionStore(core: core)
    await store.connect(serverURL: "https://dbc-1.cloud.databricks.com/?o=42")
    try await eventually("the sign-in request") {
      if case .signInRequired = store.phase { return true }
      return false
    }
    return store
  }

  private func redirect(_ challenge: DatabricksChallenge) throws -> URL {
    let authorize = try #require(URLComponents(string: challenge.authorizeUrl))
    let state = authorize.queryItems?.first { $0.name == "state" }?.value ?? ""
    return try #require(
      URL(string: "http://localhost:8123\(challenge.callbackPath)?code=abc&state=\(state)"))
  }

  @Test("A finished sign-in connects to the workspace and forgets the challenge")
  func completes() async throws {
    let store = try await workspaceStore()
    let challenge = try #require(store.beginDatabricksSignIn(loopbackPort: 8123))
    #expect(store.databricksChallenge == challenge)

    let server = await store.completeDatabricksSignIn(
      challenge, callbackURL: try redirect(challenge))
    #expect(server?.userId == "ada")
    #expect(store.databricksChallenge == nil)
  }

  @Test("A callback that doesn't match is recorded and asks for the sign-in again")
  func badCallback() async throws {
    let store = try await workspaceStore()
    let challenge = try #require(store.beginDatabricksSignIn(loopbackPort: 8123))
    store.dismissIssues()
    let forged = try #require(
      URL(string: "http://localhost:8123\(challenge.callbackPath)?code=abc&state=forged"))
    #expect(await store.completeDatabricksSignIn(challenge, callbackURL: forged) == nil)
    #expect(store.issues.count == 1)
    #expect(store.databricksChallenge == nil)
    #expect(!store.isSignedIn)
  }

  @Test("Closing the sheet abandons the sign-in; its callback can't finish later")
  func cancels() async throws {
    let store = try await workspaceStore()
    let challenge = try #require(store.beginDatabricksSignIn(loopbackPort: 8123))
    store.cancelDatabricksSignIn(challenge)
    #expect(store.databricksChallenge == nil)
    store.dismissIssues()
    #expect(
      await store.completeDatabricksSignIn(challenge, callbackURL: try redirect(challenge)) == nil)
    #expect(!store.isSignedIn)
  }

  @Test("A newer sign-in stays when an older one is abandoned")
  func olderAttempt() async throws {
    let store = try await workspaceStore()
    let older = try #require(store.beginDatabricksSignIn(loopbackPort: 8123))
    let newer = try #require(store.beginDatabricksSignIn(loopbackPort: 8123))
    #expect(older.attemptId != newer.attemptId)
    store.cancelDatabricksSignIn(older)
    #expect(store.databricksChallenge == newer)
  }

  @Test(
    "Each sign-in mode has a name for the connection details",
    arguments: [
      (AuthMode.oidc, "OpenID Connect"), (.accounts, "Accounts"), (.header, "Header"),
      (.custom, "Custom"), (.unauthenticated, "None"), (.unknown(value: "saml"), "Unknown (saml)"),
    ])
  func modeNames(mode: AuthMode, name: String) {
    #expect(mode.displayName == name)
  }

  @Test("Only a sign-in the user cancelled shows no message")
  func cancellation() {
    #expect(
      CoreError.Databricks(kind: .cancelled, message: "x", requiresSignIn: false).isCancellation)
    #expect(
      !CoreError.Databricks(kind: .authorizationDenied, message: "x", requiresSignIn: false)
        .isCancellation)
    #expect(!CoreError.InvalidState(message: "x").isCancellation)
  }

  @Test("A store over the host's services starts disconnected, using only what it was given")
  func overServices() throws {
    let suite = "connection-services-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let services = HostServices(
      http: URLSessionHttpTransport(), eventStreams: URLSessionEventStreamTransport(),
      webSockets: URLSessionWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
      secureStore: InMemorySecureStore(), entropy: SystemEntropySource(),
      settings: UserDefaultsSettingsStorage(defaults: defaults),
      managedPreferences: ManagedPreferencesSource())
    let store = ConnectionStore(
      services: services, config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    #expect(store.core != nil)
    #expect(store.phase == .disconnected)
    #expect(store.issues.isEmpty)
  }
}
