import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The saved copy of sessions that shows when the server cannot be reached.
@MainActor
@Suite("Offline from the saved copy", .serialized, .timeLimit(.minutes(1)))
struct OfflineSavedCopyTests {
  private let address = "http://127.0.0.1:6767"
  private let sessionID = "facbcc05b00f4321b98b1929d217abc5"

  /// A store over `http` whose core saves sessions under `cache`.
  private func store(
    _ http: FakeHttpTransport, streams: FakeEventStreamTransport = FakeEventStreamTransport(),
    cache: URL
  ) throws -> ConnectionStore {
    let core = try ClientCore(
      http: http, streams: streams, sockets: FakeWebSocketTransport(), clock: SystemClock(),
      scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(
        urlPolicy: .development, oidcRedirect: .none, databricks: nil,
        cacheDirectory: cache.path(percentEncoded: false)))
    return ConnectionStore(core: core)
  }

  /// A server with one session, a question and its answer.
  private func server() -> RouteServer {
    let server = RouteServer()
    server.route(
      "/v1/sessions",
      .json(
        #"{"object":"list","has_more":false,"data":[{"id":"\#(sessionID)","title":"Saved","status":"idle","created_at":1,"updated_at":2}]}"#
      ))
    server.route(
      "/v1/sessions/\(sessionID)",
      .json(
        #"{"id":"\#(sessionID)","status":"idle","created_at":1,"permission_level":4,"title":"Saved"}"#
      ))
    server.route(
      "/v1/sessions/\(sessionID)/items",
      .json(
        #"{"object":"list","has_more":false,"data":[{"id":"msg_2","type":"message","role":"assistant","content":"The answer"},{"id":"msg_1","type":"message","role":"user","content":"A question"}]}"#
      ))
    server.route(
      "/v1/sessions/\(sessionID)/resources/environments/default/changes",
      .json(#"{"entries":[]}"#))
    return server
  }

  /// The files the core saved so far.
  private func savedFiles(_ cache: URL) -> Int {
    let found = FileManager.default.enumerator(at: cache, includingPropertiesForKeys: nil)
    return found?.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.count
      ?? 0
  }

  private func scratchFolder() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "omnigent-offline-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  private func remove(_ folder: URL) {
    do {
      try FileManager.default.removeItem(at: folder)
    } catch {
      Issue.record("could not remove \(folder.path): \(error)")
    }
  }

  @Test("Offline events reach the connection and its open sessions")
  func offlineEvents() throws {
    let store = try disconnectedStore(RouteServer())
    let conversation = try #require(store.conversation("conv_a"))
    store.apply(.offlineChanged(serverUrl: address))
    #expect(store.isOffline)
    #expect(store.showsSessions)
    #expect(store.shownServerURL == address)
    store.apply(.sessionOfflineChanged(sessionId: "conv_a", offline: true))
    #expect(conversation.isOffline)
    store.apply(.sessionOfflineChanged(sessionId: "gone", offline: true))
    store.apply(.sessionOfflineChanged(sessionId: "conv_a", offline: false))
    #expect(!conversation.isOffline)
    store.apply(.offlineChanged(serverUrl: nil))
    #expect(!store.isOffline)
    #expect(!store.showsSessions)
    #expect(store.shownServerURL == nil)
  }

  @Test("Offline ending connected keeps the list; ending at a sign-in screen takes it away")
  func offlineEndsWithTheList() async throws {
    let store = try await connectedStore(server())
    try await eventually("the list") { store.sessionList.session(sessionID) != nil }
    store.apply(.offlineChanged(serverUrl: address))
    store.apply(.offlineChanged(serverUrl: nil))
    #expect(store.sessionList.session(sessionID) != nil)

    store.apply(
      .connectionChanged(
        phase: .signInRequired(
          baseUrl: address, serverName: nil, mode: .accounts, methods: [], reason: nil)))
    store.apply(.offlineChanged(serverUrl: address))
    #expect(store.showsSessions)
    store.apply(.offlineChanged(serverUrl: nil))
    #expect(store.sessionList.sessionsByID.isEmpty)
    #expect(!store.showsSessions)
  }

  @Test("A relaunch without network shows the saved sessions and transcript, marked offline")
  func offlineRelaunch() async throws {
    let cache = scratchFolder()
    defer { remove(cache) }
    let server = server()
    let streams = FakeEventStreamTransport()
    let online = try store(
      FakeHttpTransport { request throws(TransportError) in try await server.answer(request) },
      streams: streams, cache: cache)
    await online.connect(serverURL: address)
    #expect(online.isSignedIn)
    try await eventually("the list") { online.sessionList.session(sessionID) != nil }
    let conversation = try #require(online.conversation(sessionID))
    let (_, sink) = await streams.waitForOpen()
    sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    sink.chunk(bytes: Data("data: {\"type\":\"session.heartbeat\"}\n\n".utf8))
    try await eventually("the transcript") {
      conversation.isHydrated && conversation.rows.count == 2
    }
    #expect(!conversation.isOffline)
    // The list, the account and the session are written in the background.
    try await eventually("the saved copy") { savedFiles(cache) == 3 }

    let offline = try store(
      FakeHttpTransport { _ throws(TransportError) in
        throw .Offline(message: "The Internet connection appears to be offline.")
      }, cache: cache)
    let core = try #require(offline.core)
    await #expect(throws: CoreError.self) {
      _ = try await core.connect(serverUrl: address, expectedUserId: nil)
    }
    await offline.eventsSentSoFarApplied()
    #expect(offline.isOffline)
    #expect(!offline.isSignedIn)
    #expect(offline.showsSessions)
    #expect(offline.shownServerURL == address)
    #expect(offline.sessionList.session(sessionID)?.title == "Saved")
    let saved = try #require(offline.conversation(sessionID))
    try await eventually("the saved transcript") { saved.isOffline && saved.rows.count == 2 }
    #expect(saved.rows.map(\.text) == ["A question", "The answer"])
    #expect(saved.errors.isEmpty, "\(saved.errors)")
  }
}
