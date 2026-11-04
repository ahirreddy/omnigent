import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import Testing

@testable import OmnigentAppUI

#if os(macOS)
  import OmnigentDesktop
#endif

/// A new accounts server with no administrator, which `POST /auth/setup` claims.
nonisolated private let unclaimedRoutes: [String: HttpResponse] = [
  "/.well-known/omnigent.json": .json(
    #"{"manifest_version":1,"server_name":"Team","auth":{"mode":"accounts"}}"#),
  "/v1/info": .json(#"{"single_user":false,"accounts_enabled":true,"needs_setup":true}"#),
  "/auth/setup": .json(#"{"token":"tok-admin","expires_in":3600,"user":{"id":"admin"}}"#),
  "/v1/me": .json(#"{"user_id":"admin"}"#),
  "/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
]

nonisolated private let serverURL = "http://127.0.0.1:6798"

private func controller(_ http: FakeHttpTransport, defaults: UserDefaults) throws
  -> SignInController
{
  let core = try ClientCore(
    http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
    clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(),
    config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  return SignInController(store: ConnectionStore(core: core), defaults: defaults)
}

private func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Suite("Sign-in accounts and onboarding")
struct SignInAccountsTests {
  @Test(
    "An unclaimed server asks for its first admin, who is created and signed in",
    .timeLimit(.minutes(1)))
  func firstAdminIsCreated() async throws {
    let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let signIn = try controller(FakeHttpTransport(routes: unclaimedRoutes), defaults: defaults)

    await signIn.connectNow(serverURL)
    try await waitUntil("the sign-in screen") {
      if case .signInRequired = signIn.store.phase { return true }
      return false
    }
    #expect(signIn.accountForm == .createAdmin)
    guard case .createAccount(let server, .createAdmin, nil, false) = signIn.state.screen else {
      Issue.record("expected the create-admin form, got \(signIn.state.screen)")
      return
    }
    #expect(server.needsSetup)

    signIn.actions.createAccount(
      AccountCreationRequest(
        kind: .firstAdmin,
        credentials: AccountCredentials(username: "admin", password: "longenough")))
    try await waitUntil("the admin to sign in") {
      signIn.store.isSignedIn && signIn.method == nil
    }
    #expect(signIn.store.connectedServer?.userId == "admin")
    #expect(signIn.flowError == nil, "\(String(describing: signIn.flowError))")
  }

  @Test("Sign In Instead switches an unclaimed server's form back to signing in")
  func signInInstead() async throws {
    let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let signIn = try controller(FakeHttpTransport(routes: unclaimedRoutes), defaults: defaults)
    await signIn.connectNow(serverURL)
    try await waitUntil("the sign-in screen") {
      if case .signInRequired = signIn.store.phase { return true }
      return false
    }
    signIn.actions.showAccountForm(.signIn)
    guard case .password(let server, _, _) = signIn.state.screen else {
      Issue.record("expected the password form, got \(signIn.state.screen)")
      return
    }
    // The form still says the server has no administrator yet.
    #expect(server.needsSetup)
  }

  @Test("Recent servers report whether they answer as Omnigent")
  func reachability() async throws {
    let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let omnigent = try controller(FakeHttpTransport(routes: unclaimedRoutes), defaults: defaults)
    #expect(await omnigent.checkServer(serverURL) == .omnigent(name: "Team"))
    let other = try controller(FakeHttpTransport(routes: [:]), defaults: defaults)
    #expect(await other.checkServer(serverURL) == .reachable)
    let offline = try controller(
      FakeHttpTransport(failingWith: .Other(message: "offline")), defaults: defaults)
    #expect(await offline.checkServer(serverURL) == .unreachable)
  }

  @Test("Invite links are read with the core's rules")
  func inviteTokens() throws {
    let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let signIn = try controller(FakeHttpTransport(routes: [:]), defaults: defaults)
    #expect(signIn.actions.inviteToken("https://h.example.com/register?invite=abc_1") == "abc_1")
    #expect(signIn.actions.inviteToken("not an invite") == nil)
  }

  #if os(macOS)
    @Test("The local setup screens follow the manager's CLI and server")
    func localSetupState() throws {
      let endpoint = try #require(LocalServerEndpoint(port: 6767, pid: 1, manifest: nil))
      let running = LocalServerSetup.state(
        cli: .notChecked, server: .running(endpoint, .owned), log: ["ready"])
      #expect(running.server == .running(url: "http://127.0.0.1:6767"))
      #expect(running.cli == .checking)
      #expect(running.log == ["ready"])
      let missing = LocalServerSetup.state(
        cli: .missing(.cliNotFound(searched: [])), server: .stopped, log: [])
      #expect(missing.needsCLI)
      let starting = LocalServerSetup.state(cli: .checking, server: .starting(.window), log: [])
      #expect(starting.server == .busy("Starting\u{2026}"))
    }

    @Test("Hosting waits for a sign-in to the same origin")
    func hostMatchesTheOrigin() {
      #expect(
        LocalServerSetup.sameServer(
          "https://omnigent.example.com", "https://OMNIGENT.example.com/api/omnigent"))
      #expect(
        !LocalServerSetup.sameServer("https://omnigent.example.com", "https://other.example.com"))
      #expect(!LocalServerSetup.sameServer("not a url", "not a url"))
    }
  #endif
}
