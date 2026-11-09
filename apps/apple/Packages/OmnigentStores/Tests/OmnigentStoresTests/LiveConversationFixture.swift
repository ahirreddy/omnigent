import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// The recorded session the fixture's server knows.
nonisolated let liveSessionID = "facbcc05b00f4321b98b1929d217abc5"

/// Holds a POST to a session's events until the test answers it.
final class EventsGate: Sendable {
  private let answer = Mutex<CheckedContinuation<HttpResponse, Never>?>(nil)
  private let items = Mutex(#"{"object":"list","data":[],"has_more":false}"#)

  var isWaiting: Bool { answer.withLock { $0 != nil } }

  func setItems(_ json: String) { items.withLock { $0 = json } }

  func respond(_ request: HttpRequest, routes: [String: HttpResponse]) async -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    if request.method == "POST", path == "/v1/sessions/\(liveSessionID)/events" {
      return await withCheckedContinuation { continuation in
        answer.withLock { $0 = continuation }
      }
    }
    if path == "/v1/sessions/\(liveSessionID)/items" { return .json(items.withLock { $0 }) }
    return routes[path] ?? .json(#"{"detail":"not found"}"#, status: 404)
  }

  func release(_ response: HttpResponse) {
    let waiting = answer.withLock { state in
      defer { state = nil }
      return state
    }
    waiting?.resume(returning: response)
  }
}

/// A connected store with one conversation live against an ``EventsGate``.
@MainActor
enum LiveConversationFixture {
  static func fixtureResponse(_ path: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "client-core/fixtures/\(path)")
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    let data = try JSONSerialization.data(withJSONObject: try #require(object["response"]))
    return try #require(String(data: data, encoding: .utf8))
  }

  static func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while !condition() {
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out waiting for \(what)")
        return
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  static func connected(
    _ gate: EventsGate, streams: FakeEventStreamTransport = FakeEventStreamTransport()
  ) async throws -> (ConnectionStore, ConversationStore) {
    let routes: [String: HttpResponse] = [
      "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth),
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      "/v1/me": .json(#"{"user_id":"local"}"#),
      "/v1/sessions": .json(try fixtureResponse("sessions/recorded-sessions-list.json")),
      "/v1/sessions/\(liveSessionID)": .json(
        try fixtureResponse("sessions/recorded-session-get-no-items.json")),
      "/v1/sessions/\(liveSessionID)/resources/environments/default/changes": .json(
        #"{"entries":[]}"#),
    ]
    let http = FakeHttpTransport { request throws(TransportError) in
      await gate.respond(request, routes: routes)
    }
    let core = try ClientCore(
      http: http, streams: streams, sockets: FakeWebSocketTransport(), clock: SystemClock(),
      scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let connection = ConnectionStore(core: core)
    await connection.connect(serverURL: "http://127.0.0.1:6767")
    let conversation = try #require(connection.conversation(liveSessionID))
    // The connection's own update stream may open first.
    var opened = await streams.waitForOpen()
    while !opened.0.url.hasSuffix("/v1/sessions/\(liveSessionID)/stream") {
      opened = await streams.waitForOpen()
    }
    opened.1.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    let heartbeat = #"{"sequence_number": null, "type": "session.heartbeat", "server_time": null}"#
    opened.1.chunk(bytes: Data("event: session.heartbeat\ndata: \(heartbeat)\n\n".utf8))
    try await waitUntil("the session to accept messages") { conversation.isHydrated }
    return (connection, conversation)
  }
}
