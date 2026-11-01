import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

nonisolated private let sessionID = "facbcc05b00f4321b98b1929d217abc5"

/// `client-core/fixtures`, found from this file's path.
nonisolated private let fixturesURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()  // this file
  .deletingLastPathComponent()  // OmnigentStoresTests
  .deletingLastPathComponent()  // Tests
  .deletingLastPathComponent()  // OmnigentStores
  .deletingLastPathComponent()  // Packages
  .deletingLastPathComponent()  // apple
  .deletingLastPathComponent()  // apps
  .appending(path: "client-core/fixtures")

nonisolated private func fixture(_ path: String) throws -> Data {
  try Data(contentsOf: fixturesURL.appending(path: path))
}

/// The `response` of a recorded `{request, status, response}` envelope.
nonisolated private func envelopeResponse(_ path: String) throws -> String {
  let object = try #require(
    try JSONSerialization.jsonObject(with: fixture(path)) as? [String: Any])
  let response = try #require(object["response"])
  let data = try JSONSerialization.data(withJSONObject: response)
  return try #require(String(data: data, encoding: .utf8))
}

/// One recorded SSE frame: its decoded `data` and its wire text.
private struct Frame {
  let data: [String: Any]
  let raw: String
}

private func recordedFrames(_ path: String) throws -> [Frame] {
  let text = try #require(String(data: fixture(path), encoding: .utf8))
  return try text.split(separator: "\n").map { line in
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any])
    let raw = try #require(object["raw"] as? String)
    return Frame(data: data, raw: raw + "\n\n")
  }
}

/// `/items` (newest first) once `frames` were committed. A function call's id changes when it
/// completes, so calls key by `call_id`.
private func itemsPage(_ frames: ArraySlice<Frame>) throws -> String {
  var items: [[String: Any]] = []
  for frame in frames {
    var item: [String: Any]
    switch frame.data["type"] as? String {
    case "response.output_item.done":
      item = try #require(frame.data["item"] as? [String: Any])
    case "session.input.consumed":
      let consumed = try #require(frame.data["data"] as? [String: Any])
      item = try #require(consumed["data"] as? [String: Any])
      item["id"] = consumed["item_id"]
      item["type"] = consumed["type"]
    default:
      continue
    }
    func key(_ value: [String: Any]) -> String {
      if value["type"] as? String == "function_call", let callID = value["call_id"] as? String {
        return callID
      }
      return value["id"] as? String ?? ""
    }
    let itemKey = key(item)
    items.removeAll { key($0) == itemKey }
    items.append(item)
  }
  let page: [String: Any] = ["object": "list", "data": Array(items.reversed()), "has_more": false]
  let data = try JSONSerialization.data(withJSONObject: page)
  return try #require(String(data: data, encoding: .utf8))
}

/// A loopback single-user server whose history the test advances.
nonisolated private final class FixtureServer: Sendable {
  let items = Mutex("{\"object\":\"list\",\"data\":[],\"has_more\":false}")
  let routes: [String: HttpResponse]

  init() throws {
    routes = [
      "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth),
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      "/v1/me": .json(#"{"user_id":"local"}"#),
      "/v1/sessions": .json(try envelopeResponse("sessions/recorded-sessions-list.json")),
      "/v1/sessions/\(sessionID)": .json(
        try envelopeResponse("sessions/recorded-session-get-no-items.json")),
      "/v1/sessions/\(sessionID)/resources/environments/default/changes": .json(
        #"{"entries":[]}"#),
    ]
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    if path == "/v1/sessions/\(sessionID)/items" {
      return .json(items.withLock { $0 })
    }
    return routes[path] ?? .json(#"{"detail":"not found"}"#, status: 404)
  }
}

@MainActor
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

/// Waits until the store has applied every event the core sent so far.
@MainActor
private func settle(_ store: ConnectionStore) async throws {
  var last = -1
  var stable = 0
  while stable < 3 {
    try await Task.sleep(for: .milliseconds(15))
    if store.eventsApplied == last {
      stable += 1
    } else {
      stable = 0
      last = store.eventsApplied
    }
  }
}

@MainActor
private func makeStore(
  server: FixtureServer, streams: FakeEventStreamTransport, sockets: FakeWebSocketTransport
) throws -> ConnectionStore {
  let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
  let core = try ClientCore(
    http: http, streams: streams, sockets: sockets, clock: SystemClock(),
    scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  return ConnectionStore(core: core)
}

@MainActor
struct CoreDrivenStoreTests {
  @Test func connectsAndListsSessions() async throws {
    let store = try makeStore(
      server: try FixtureServer(), streams: FakeEventStreamTransport(),
      sockets: FakeWebSocketTransport())

    await store.connect(serverURL: "http://127.0.0.1:6767")

    #expect(store.isSignedIn, "phase: \(store.phase)")
    #expect(store.connectedServer?.userId == "local")
    try await waitUntil("the session list") { store.sessionList.isLoaded }
    #expect(store.sessionList.visible.count == 3)
    #expect(store.sessionList.session(sessionID)?.title == "fixture turn session")
    #expect(store.issues.isEmpty, "\(store.issues)")
  }

  @Test func recordedTurnStreamsIntoConversationRows() async throws {
    let server = try FixtureServer()
    let streams = FakeEventStreamTransport()
    let store = try makeStore(server: server, streams: streams, sockets: FakeWebSocketTransport())
    await store.connect(serverURL: "http://127.0.0.1:6767")
    let conversation = try #require(store.conversation(sessionID))

    let (request, sink) = await streams.waitForOpen()
    #expect(request.url.hasSuffix("/v1/sessions/\(sessionID)/stream"))
    sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    let frames = try recordedFrames("sse/recorded-turn-text-tool-completion.jsonl")
    for index in frames.indices {
      let page = try itemsPage(frames[...index])
      server.items.withLock { $0 = page }
      let bytes = Data(frames[index].raw.utf8)
      sink.chunk(bytes: bytes.prefix(bytes.count / 2))
      sink.chunk(bytes: bytes.suffix(from: bytes.count / 2))
      try await settle(store)
    }

    try await waitUntil("the finished turn") {
      conversation.header?.status == .idle && conversation.transcriptRows.count == 4
    }
    let rows = conversation.transcriptRows
    #expect(conversation.isHydrated)
    #expect(conversation.link == .live)
    let ephemeral = conversation.rows.filter(\.isEphemeral)
    #expect(ephemeral.isEmpty, "\(ephemeral)")
    #expect(rows.map(\.role) == [.user, .tool, .tool, .assistant])
    #expect(rows.first?.text.contains("echo fixture-hello") == true)
    #expect(rows.last?.text == "The command printed fixture-hello.")
    #expect(conversation.errors.isEmpty, "\(conversation.errors)")
  }

  @Test func demoCoreBacksPreviews() async throws {
    let store = try await PreviewData.connectedDemoStore()
    try await waitUntil("the sample list") { !store.sessionList.visible.isEmpty }
    let first = try #require(store.sessionList.visible.first)
    let conversation = try #require(store.conversation(first.id))
    try await waitUntil("sample rows") { !conversation.rows.isEmpty }
    #expect(conversation.isHydrated)
  }
}

@MainActor
struct RowOpTests {
  private func row(_ id: String, _ text: String = "") -> Row {
    Row(
      id: id, role: .assistant, text: text, isStreaming: false, activity: nil, attachments: [],
      callId: nil, responseId: nil, interrupted: false, author: nil, agent: nil,
      isEphemeral: false, isActivityOnly: false)
  }

  @Test func appliesOpsInOrderLikeTheCore() throws {
    let ops: [RowOp] = [
      .insert(index: 0, row: row("a")),
      .insert(index: 1, row: row("b")),
      .update(index: 0, row: row("a", "edited")),
      .remove(id: "b"),
      .insert(index: 0, row: row("c")),
    ]
    var rows: [Row] = []
    try applyRowOps(ops, to: &rows)
    let reference = try OmnigentCoreFFI.applyRowOps(rows: [], ops: ops)
    #expect(rows == reference)
    #expect(rows.map(\.id) == ["c", "a"])
  }

  @Test func rejectsOpsThatDoNotFit() {
    var rows = [row("a")]
    #expect(throws: RowOpMismatch.self) {
      try applyRowOps([.update(index: 0, row: row("z"))], to: &rows)
    }
    #expect(throws: RowOpMismatch.self) {
      try applyRowOps([.remove(id: "missing")], to: &rows)
    }
  }
}

@MainActor
struct SessionListStoreTests {
  private func summary(
    _ id: String, updatedAt: Int64, pinned: Bool = false, status: SessionListStatus = .idle
  ) -> SessionSummary {
    SessionSummary(
      id: id, title: id, preview: "", status: status, isReadOnly: false, updatedAt: updatedAt,
      workspace: "", agentName: "", isPinned: pinned, isArchived: false, permissionLevel: 4,
      failureMessage: nil, canRename: true, canPin: true, canArchive: true)
  }

  @Test func ordersAndFiltersThroughTheCore() {
    let store = SessionListStore()
    store.apply(
      .reset(sessions: [summary("old", updatedAt: 1), summary("new", updatedAt: 3)]))
    store.apply(.upsert(sessions: [summary("pin", updatedAt: 0, pinned: true)]))
    #expect(store.visible.map(\.id) == ["pin", "new", "old"])
    store.apply(.remove(ids: ["new"]))
    #expect(store.visible.map(\.id) == ["pin", "old"])
    store.searchText = "ol"
    #expect(store.visible.map(\.id) == ["old"])
  }

  @Test func anExpectedStatusShowsUntilTheNextServerRow() throws {
    let store = SessionListStore()
    store.apply(.reset(sessions: [summary("a", updatedAt: 1, status: .needsResponse)]))
    #expect(store.needsResponse.map(\.id) == ["a"])

    try #require(store.expect(.running, for: "a") != nil)
    #expect(store.session("a")?.status == .running)
    #expect(store.needsResponse.isEmpty)

    // The server's next row wins, whichever status it carries.
    store.apply(.upsert(sessions: [summary("a", updatedAt: 2, status: .needsResponse)]))
    #expect(store.session("a")?.status == .needsResponse)
  }

  @Test func aWithdrawnExpectationRevertsAndUnknownSessionsAreLeftAlone() throws {
    let store = SessionListStore()
    store.apply(.reset(sessions: [summary("a", updatedAt: 1, status: .running)]))
    #expect(store.expect(.idle, for: "missing") == nil)
    #expect(store.session("missing") == nil)

    let first = try #require(store.expect(.idle, for: "a"))
    let second = try #require(store.expect(.idle, for: "a"))
    // An older token no longer owns the expectation.
    store.withdrawExpectation(first, for: "a")
    #expect(store.session("a")?.status == .idle)
    store.withdrawExpectation(second, for: "a")
    #expect(store.session("a")?.status == .running)
  }

  @Test(.timeLimit(.minutes(1))) func anExpectationExpiresWithoutAServerRow() async throws {
    let store = SessionListStore()
    store.expectationLifetime = .milliseconds(20)
    store.apply(.reset(sessions: [summary("a", updatedAt: 1, status: .running)]))
    try #require(store.expect(.idle, for: "a") != nil)
    #expect(store.session("a")?.status == .idle)
    let deadline = ContinuousClock.now + .seconds(10)
    while store.session("a")?.status != .running, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.session("a")?.status == .running)
  }
}
