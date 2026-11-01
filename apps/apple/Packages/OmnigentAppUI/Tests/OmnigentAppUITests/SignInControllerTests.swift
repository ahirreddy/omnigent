import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import Testing

@testable import OmnigentAppUI

/// An accounts-mode server on a loopback root, as `omnigent server` with
/// `OMNIGENT_AUTH_PROVIDER=accounts` answers.
nonisolated private let accountsRoutes: [String: HttpResponse] = [
  "/.well-known/omnigent.json": .json(#"{"manifest_version":1,"auth":{"mode":"accounts"}}"#),
  "/v1/info": .json(#"{"single_user":false,"accounts_enabled":true,"login_url":"/login"}"#),
  "/auth/login": .json(#"{"token":"tok-loop","expires_in":3600,"user":{"id":"u1"}}"#),
  "/v1/me": .json(#"{"user_id":"u1"}"#),
  "/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
]

nonisolated private let serverURL = "http://127.0.0.1:6797"

/// A controller over a fresh core, as one app launch has. Launches share `secureStore` (the
/// Keychain) and `defaults`.
private func launch(secureStore: InMemorySecureStore, defaults: UserDefaults) throws
  -> SignInController
{
  let core = try ClientCore(
    http: FakeHttpTransport(routes: accountsRoutes), streams: FakeEventStreamTransport(),
    sockets: FakeWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
    secureStore: secureStore, entropy: FixedEntropySource(),
    config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  return SignInController(store: ConnectionStore(core: core), defaults: defaults)
}

private func waitUntil(
  _ description: String, timeout: Duration = .seconds(10), _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Suite("Sign-in controller")
struct SignInControllerTests {
  @Test(
    "A password sign-in is restored on the next launch without the password",
    .timeLimit(.minutes(1)))
  func passwordSignInIsRestored() async throws {
    let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let secureStore = InMemorySecureStore()

    let first = try launch(secureStore: secureStore, defaults: defaults)
    await first.connectNow(serverURL)
    // The store's phase follows the core's events, which can land after the call returns.
    try await waitUntil("the password form") {
      if case .signInRequired = first.store.phase { return true }
      return false
    }
    first.actions.submitCredentials(AccountCredentials(username: "ada", password: "pw"))
    try await waitUntil("the sign-in to finish") {
      first.store.isSignedIn && first.method == nil
    }
    #expect(first.flowError == nil, "\(String(describing: first.flowError))")
    #expect(RememberedAccounts(defaults: defaults).user(for: serverURL) == "u1")

    // The next launch restores the account from the saved credential.
    let second = try launch(secureStore: secureStore, defaults: defaults)
    await second.connectNow(serverURL)
    try await waitUntil("the restored connection") { second.store.isSignedIn }
    #expect(second.store.connectedServer?.userId == "u1")
    #expect(second.flowError == nil, "\(String(describing: second.flowError))")
  }

  @Test(
    "Signing in and restoring both report the signed-in server once, from the call's result",
    .timeLimit(.minutes(1)))
  func signedInIsReportedForSignInAndRestore() async throws {
    let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let secureStore = InMemorySecureStore()

    let first = try launch(secureStore: secureStore, defaults: defaults)
    var firstReports: [String] = []
    first.onSignedIn = { firstReports.append($0.baseUrl) }
    await first.connectNow(serverURL)
    #expect(firstReports.isEmpty, "a sign-in-required connect reported a signed-in server")
    try await waitUntil("the password form") {
      if case .signInRequired = first.store.phase { return true }
      return false
    }
    first.actions.submitCredentials(AccountCredentials(username: "ada", password: "pw"))
    try await waitUntil("the sign-in report") { !firstReports.isEmpty }
    #expect(firstReports.count == 1)

    let second = try launch(secureStore: secureStore, defaults: defaults)
    var secondReports: [String] = []
    second.onSignedIn = { secondReports.append($0.baseUrl) }
    await second.connectNow(serverURL)
    // The restore is reported when connectNow returns, before the phase event may have landed.
    #expect(secondReports.count == 1)
  }
}

#if DEBUG && os(macOS)
  @Suite("Debug keychain fallback")
  struct KeychainModeSelectionTests {
    @Test("The running build's identity is its code directory hash")
    func buildIdentity() throws {
      let identity = try KeychainModeSelection.buildIdentity().get()
      #expect(identity.count == 40, "\(identity)")
      #expect(identity.allSatisfy { $0.isHexDigit })
      #expect(identity == identity.lowercased())
    }
  }
#endif
