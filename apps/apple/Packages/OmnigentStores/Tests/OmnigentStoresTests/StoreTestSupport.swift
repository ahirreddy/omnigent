import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// Holds requests to one route until the test releases them, to catch a store mid-request.
nonisolated final class RouteGate: Sendable {
  private struct State {
    var arrivals = 0
    var isReleased = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  private let state = Mutex(State())

  /// Requests that reached the gate so far.
  var arrivals: Int { state.withLock { $0.arrivals } }

  func pass() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let isOpen = state.withLock { state -> Bool in
        state.arrivals += 1
        if state.isReleased { return true }
        state.waiters.append(continuation)
        return false
      }
      if isOpen { continuation.resume() }
    }
  }

  func release() {
    let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.isReleased = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }
}

/// A loopback single-user server answering by method and path, then by path.
nonisolated final class RouteServer: Sendable {
  private let routes = Mutex<[String: HttpResponse]>([:])
  private let gates = Mutex<[String: RouteGate]>([:])
  private let transportFailures = Mutex<[String: TransportError]>([:])
  private let received = Mutex<[HttpRequest]>([])

  init() {
    route("/.well-known/omnigent.json", .json(ManifestFixtures.localNoAuth))
    route("/v1/info", .json(#"{"single_user":true,"accounts_enabled":false}"#))
    route("/v1/me", .json(#"{"user_id":"local"}"#))
    route("/v1/sessions", .json(#"{"object":"list","data":[],"has_more":false}"#))
  }

  func route(_ path: String, method: String? = nil, _ response: HttpResponse) {
    routes.withLock { $0[Self.key(path, method)] = response }
  }

  /// Answers `path` with a JSON error body and `status`.
  func fail(_ path: String, method: String? = nil, status: UInt16 = 500, detail: String = "boom") {
    route(path, method: method, .json(#"{"detail":"\#(detail)"}"#, status: status))
  }

  /// Fails `path` below HTTP, as a dropped connection does.
  func dropConnection(_ path: String, method: String? = nil) {
    transportFailures.withLock {
      $0[Self.key(path, method)] = .Other(message: "connection lost")
    }
  }

  /// Holds requests to `path` until the returned gate is released.
  func hold(_ path: String, method: String? = nil) -> RouteGate {
    let gate = RouteGate()
    gates.withLock { $0[Self.key(path, method)] = gate }
    return gate
  }

  /// Every request so far whose path is `path`, or every request.
  func requests(to path: String? = nil, method: String? = nil) -> [HttpRequest] {
    received.withLock { $0 }.filter { request in
      (path == nil || URLComponents(string: request.url)?.path == path)
        && (method == nil || request.method == method)
    }
  }

  /// The JSON object a request carried.
  func body(of request: HttpRequest) throws -> [String: Any] {
    let data = try #require(request.body)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    return routes.withLock { $0["\(request.method) \(path)"] ?? $0[path] }
      ?? .json(#"{"detail":"not found"}"#, status: 404)
  }

  func answer(_ request: HttpRequest) async throws(TransportError) -> HttpResponse {
    received.withLock { $0.append(request) }
    let path = URLComponents(string: request.url)?.path ?? ""
    let exact = "\(request.method) \(path)"
    let gate = gates.withLock { $0[exact] ?? $0[path] }
    if let gate { await gate.pass() }
    let failure = transportFailures.withLock { $0[exact] ?? $0[path] }
    if let failure { throw failure }
    return respond(request)
  }

  private static func key(_ path: String, _ method: String?) -> String {
    (method.map { "\($0) " } ?? "") + path
  }
}

/// A store over `server`, not yet connected.
@MainActor
func disconnectedStore(
  _ server: RouteServer, streams: FakeEventStreamTransport = FakeEventStreamTransport(),
  sockets: FakeWebSocketTransport = FakeWebSocketTransport(),
  secureStore: InMemorySecureStore = InMemorySecureStore()
) throws -> ConnectionStore {
  let http = FakeHttpTransport { request throws(TransportError) in try await server.answer(request)
  }
  let core = try ClientCore(
    http: http, streams: streams, sockets: sockets, clock: SystemClock(),
    scheduler: TaskScheduler(), secureStore: secureStore,
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  return ConnectionStore(core: core)
}

/// A store signed in to `server`.
@MainActor
func connectedStore(
  _ server: RouteServer, streams: FakeEventStreamTransport = FakeEventStreamTransport(),
  sockets: FakeWebSocketTransport = FakeWebSocketTransport()
) async throws -> ConnectionStore {
  let store = try disconnectedStore(server, streams: streams, sockets: sockets)
  await store.connect(serverURL: "http://127.0.0.1:6767")
  #expect(store.isSignedIn, "phase: \(store.phase)")
  return store
}

/// Waits for an asynchronous effect a store has no completion for.
@MainActor
func eventually(
  _ description: String, sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
      return
    }
    try await Task.sleep(for: .milliseconds(5))
  }
}
