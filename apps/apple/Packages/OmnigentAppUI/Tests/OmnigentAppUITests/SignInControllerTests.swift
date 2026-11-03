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

#if os(macOS)
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

  /// The system browser, faked: records the page it was asked to open and, like a browser
  /// after the user signs in, requests the redirect with a code and the page's state.
  @MainActor
  private final class FakeBrowser {
    private(set) var opened: [URL] = []
    private(set) var redirectError: (any Error)?

    func open(_ url: URL) -> Bool {
      opened.append(url)
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      guard let redirect = items.first(where: { $0.name == "redirect_uri" })?.value,
        let state = items.first(where: { $0.name == "state" })?.value,
        let callback = URL(string: "\(redirect)/?code=abc&state=\(state)")
      else { return false }
      Task {
        do {
          let session = URLSession(configuration: .ephemeral)
          defer { session.finishTasksAndInvalidate() }
          _ = try await session.data(from: callback)
        } catch {
          redirectError = error
        }
      }
      return true
    }
  }

  @Suite("Databricks sign-in on the Mac")
  struct DatabricksLoopbackSignInTests {
    @Test(
      "The published client's localhost redirect is received on a loopback port",
      .timeLimit(.minutes(1)))
    func loopbackSignIn() async throws {
      let suite = "ai.omnigent.appui.tests.\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      let core = try ClientCore(
        http: FakeHttpTransport(routes: workspaceRoutes), streams: FakeEventStreamTransport(),
        sockets: FakeWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
        secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
        config: HostConfig(
          urlPolicy: .development, oidcRedirect: .none,
          databricks: DatabricksOAuthSettings(clientId: "omnigent", redirectUrl: "http://localhost")
        ))
      let browser = FakeBrowser()
      let controller = SignInController(
        store: ConnectionStore(core: core), opener: ExternalURLOpener { browser.open($0) },
        defaults: defaults)

      await controller.connectNow("https://dbc-1.cloud.databricks.com/?o=42")
      try await waitUntil("the workspace sign-in") {
        if case .signInRequired = controller.store.phase { return true }
        return false
      }
      controller.actions.startBrowserSignIn(
        .databricksWorkspace(workspaceHost: "dbc-1.cloud.databricks.com"))
      try await waitUntil("the sign-in to finish") {
        controller.store.isSignedIn && controller.method == nil
      }

      #expect(controller.flowError == nil, "\(String(describing: controller.flowError))")
      #expect(browser.redirectError == nil, "\(String(describing: browser.redirectError))")
      #expect(controller.store.connectedServer?.userId == "ada")
      let opened = try #require(browser.opened.first)
      #expect(
        opened.host() == "dbc-1.cloud.databricks.com" && opened.path() == "/oidc/v1/authorize")
      let redirect = URLComponents(url: opened, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "redirect_uri" }?.value
      #expect(redirect?.hasPrefix("http://localhost:") == true, "\(redirect ?? "none")")
    }
  }
#endif

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
