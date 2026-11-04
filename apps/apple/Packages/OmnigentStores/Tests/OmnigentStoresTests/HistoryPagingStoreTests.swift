import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

nonisolated private let pagedSessionID = "facbcc05b00f4321b98b1929d217abc5"

/// A newest-first `/items` page of assistant messages.
nonisolated private func messagePage(_ ids: [String], hasMore: Bool) -> String {
  let data = ids.map { #"{"id":"\#($0)","type":"message","role":"assistant","content":"\#($0)"}"# }
  let last = ids.last.map { #","last_id":"\#($0)""# } ?? ""
  return
    #"{"object":"list","data":[\#(data.joined(separator: ","))],"has_more":\#(hasMore)\#(last)}"#
}

/// A loopback single-user server whose history pages by the `after` cursor.
nonisolated private final class PagedServer: Sendable {
  let routes: [String: HttpResponse]

  init() throws {
    let fixtures = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "client-core/fixtures")
    let envelope = try Data(
      contentsOf: fixtures.appending(path: "sessions/recorded-session-get-no-items.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: envelope) as? [String: Any])
    let session = try JSONSerialization.data(withJSONObject: try #require(object["response"]))
    routes = [
      "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth),
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      "/v1/me": .json(#"{"user_id":"local"}"#),
      "/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
      "/v1/sessions/\(pagedSessionID)": .json(try #require(String(data: session, encoding: .utf8))),
      "/v1/sessions/\(pagedSessionID)/resources/environments/default/changes": .json(
        #"{"entries":[]}"#),
    ]
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let components = URLComponents(string: request.url)
    if components?.path == "/v1/sessions/\(pagedSessionID)/items" {
      let after = components?.queryItems?.first { $0.name == "after" }?.value
      return .json(
        after == "msg_2"
          ? messagePage(["msg_1"], hasMore: false) : messagePage(["msg_3", "msg_2"], hasMore: true))
    }
    return routes[components?.path ?? ""] ?? .json(#"{"detail":"not found"}"#, status: 404)
  }
}

@MainActor
struct HistoryPagingStoreTests {
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

  @Test func olderHistoryLoadsAboveTheRows() async throws {
    let server = try PagedServer()
    let streams = FakeEventStreamTransport()
    let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
    let core = try ClientCore(
      http: http, streams: streams, sockets: FakeWebSocketTransport(), clock: SystemClock(),
      scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let store = ConnectionStore(core: core)
    await store.connect(serverURL: "http://127.0.0.1:6767")
    let conversation = try #require(store.conversation(pagedSessionID))

    let (_, sink) = await streams.waitForOpen()
    sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    sink.chunk(bytes: Data("data: {\"type\":\"session.heartbeat\"}\n\n".utf8))
    try await waitUntil("the newest page") { conversation.hasOlderHistory }
    #expect(conversation.rows.map(\.id) == ["msg_2", "msg_3"])

    conversation.loadOlderHistory()
    try await waitUntil("the older page") {
      !conversation.hasOlderHistory && !conversation.isLoadingOlderHistory
    }
    #expect(conversation.rows.map(\.id) == ["msg_1", "msg_2", "msg_3"])
    #expect(conversation.errors.isEmpty, "\(conversation.errors)")
  }
}
