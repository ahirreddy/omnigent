import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentAppUI

/// A loopback server by route, signed in with no auth, that keeps what each request sent.
nonisolated final class AppServer: Sendable {
  private final class Routes: Sendable {
    let table = Mutex<[String: HttpResponse]>([:])
  }

  private let routes = Routes()
  let http: FakeHttpTransport

  init() {
    let routes = routes
    http = FakeHttpTransport { request throws(TransportError) in
      let path = URLComponents(string: request.url)?.path ?? ""
      return routes.table.withLock { $0["\(request.method) \(path)"] ?? $0[path] }
        ?? .json(#"{"detail":"not found"}"#, status: 404)
    }
    route("/.well-known/omnigent.json", .json(ManifestFixtures.localNoAuth))
    route("/v1/info", .json(#"{"single_user":true,"accounts_enabled":false}"#))
    route("/v1/me", .json(#"{"user_id":"local"}"#))
    route("/v1/sessions", .json(#"{"object":"list","data":[],"has_more":false}"#))
  }

  /// Answers `path`, for one method or for all of them.
  func route(_ path: String, method: String? = nil, _ response: HttpResponse) {
    routes.table.withLock { $0[(method.map { "\($0) " } ?? "") + path] = response }
  }

  /// The requests sent to `path` with `method`.
  func requests(_ method: String, _ path: String) -> [HttpRequest] {
    http.requests.filter {
      $0.method == method && URLComponents(string: $0.url)?.path == path
    }
  }

  /// The JSON bodies patched to `path`.
  func patched(_ path: String) throws -> [[String: Any]] {
    try requests("PATCH", path).map { request in
      let body = try #require(request.body)
      return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
  }

  /// The JSON bodies posted to `path`.
  func posted(_ path: String) throws -> [[String: Any]] {
    try requests("POST", path).map { request in
      let body = try #require(request.body)
      return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
  }
}

/// A store signed in to `server`.
@MainActor
func signedInStore(_ server: AppServer) async throws -> ConnectionStore {
  let core = try ClientCore(
    http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
    clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let store = ConnectionStore(core: core)
  await store.connect(serverURL: "http://127.0.0.1:6767")
  #expect(store.isSignedIn, "phase: \(store.phase)")
  return store
}

/// Waits for what a detached task or the core's events will do.
@MainActor
func eventually(
  _ description: String, timeout: Duration = .seconds(5), _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}
