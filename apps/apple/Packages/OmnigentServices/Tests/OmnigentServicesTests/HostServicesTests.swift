import AuthenticationServices
import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentServices

/// The bundle the app runs on, and the core running over it against a local server. Credentials
/// stay in a temporary folder, so nothing here reaches the Keychain.
@Suite("Host services") struct HostServicesTests {
  private func temporaryFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "host-services-\(UUID().uuidString)")
  }

  @Test("The live bundle keeps credentials in the given folder and settings in the given defaults")
  func liveBundle() async throws {
    let folder = temporaryFolder()
    defer { #expect(throws: Never.self) { try removeIfPresent(folder) } }
    let suite = "host-services-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let services = HostServices.live(defaults: defaults, credentialDirectory: folder)
    let key = SecureStoreKey(namespace: "oidc", account: "https://example.com")
    try await services.secureStore.set(key: key, value: Data("grant".utf8))
    #expect(try await services.secureStore.get(key: key) == Data("grant".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)

    try services.settings.set(key: "omnigent.name", value: "\"value\"")
    #expect(defaults.string(forKey: "omnigent.name") == "value")
    let unset = "omnigent.unset.\(suite)"
    #expect(services.managedPreferences.value(key: unset, domain: suite) == nil)
    #expect(!services.managedPreferences.isForced(key: unset, domain: suite))
  }

  private func removeIfPresent(_ folder: URL) throws {
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }

  /// A connected server answering the discovery and list routes, recording the rest.
  private func localServer() async throws -> MockHTTPServer {
    try await MockHTTPServer.start { request in
      let json = { (text: String) -> MockHTTPServer.Response in
        .complete(status: 200, headers: ["Content-Type": "application/json"], body: Data(text.utf8))
      }
      switch request.path {
      case "/.well-known/omnigent.json": return json(ManifestFixtures.localNoAuth)
      case "/v1/info": return json(#"{"single_user":true,"accounts_enabled":false}"#)
      case "/v1/me": return json(#"{"user_id":"local"}"#)
      case "/v1/sessions": return json(#"{"object":"list","data":[],"has_more":false}"#)
      default: return .complete(status: 404, headers: [:], body: Data())
      }
    }
  }

  @Test("The core connects over these transports: its jobs run, and it opens its live links")
  func coreRunsOverTheTransports() async throws {
    let server = try await localServer()
    defer { server.stop() }
    let core = try ClientCore(
      http: URLSessionHttpTransport(), streams: URLSessionEventStreamTransport(),
      sockets: URLSessionWebSocketTransport(), clock: SystemClock(), scheduler: TaskScheduler(),
      secureStore: InMemorySecureStore(), entropy: SystemEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))

    _ = try await core.discoverServer(serverUrl: server.url(for: ""))
    let phase = try await core.connect(serverUrl: server.url(for: ""), expectedUserId: nil)
    guard case .connected(let connected) = phase else {
      Issue.record("phase: \(phase)")
      return
    }
    #expect(connected.userId == "local")

    // A scheduled job read the list, and the updates socket and a session's stream were tried.
    #expect(
      await eventually { server.requests.contains { $0.path == "/v1/sessions" } })
    #expect(
      await eventually { server.requests.contains { $0.path.hasSuffix("/updates") } },
      "\(server.requests.map(\.path))")
    core.openSession(sessionId: "conv_a")
    #expect(
      await eventually { server.requests.contains { $0.path == "/v1/sessions/conv_a/stream" } },
      "\(server.requests.map(\.path))")
    core.closeSession(sessionId: "conv_a")
  }
}

/// What doesn't need a sheet on screen: every path here ends before one would be presented.
@MainActor
@Suite("Web sign-in without a sheet") struct WebAuthenticationOutcomeTests {
  private let page = URL(filePath: "/")

  @Test("Dismissing the sheet is a cancellation, not an error to show")
  func cancelled() {
    let error = ASWebAuthenticationSessionError(.canceledLogin)
    #expect(
      WebAuthenticationPresenter.outcome(callbackURL: nil, error: error) == .failure(.cancelled))
  }

  @Test("Any other session error carries its description")
  func otherError() {
    let error = URLError(.notConnectedToInternet)
    #expect(
      WebAuthenticationPresenter.outcome(callbackURL: nil, error: error)
        == .failure(.failed(message: error.localizedDescription)))
  }

  @Test("A session with neither a callback nor an error fails, and a callback is returned")
  func callbacks() throws {
    #expect(
      WebAuthenticationPresenter.outcome(callbackURL: nil, error: nil)
        == .failure(.failed(message: "The sign-in session ended without a callback URL.")))
    let callback = try #require(URL(string: "ai.omnigent:/cb?code=1"))
    #expect(
      WebAuthenticationPresenter.outcome(callbackURL: callback, error: nil) == .success(callback))
  }

  @Test("With no window to attach to, the sign-in fails before any sheet")
  func noWindow() async {
    await #expect(
      throws: WebAuthenticationError.failed(
        message: "No window is available to present the sign-in sheet.")
    ) {
      _ = try await WebAuthenticationPresenter().authenticate(
        url: page, callback: .customScheme("ai.omnigent"),
        anchorProvider: KeyWindowAnchorProvider())
    }
  }
}
