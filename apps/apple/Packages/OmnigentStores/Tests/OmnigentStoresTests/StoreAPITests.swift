import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Synchronization
import Testing

@testable import OmnigentStores

/// `client-core/fixtures`, found from this file's path.
nonisolated private let fixtureRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appending(path: "client-core/fixtures")

/// The `response` of a recorded `{request, status, response}` envelope, as JSON text.
nonisolated private func recorded(_ path: String) throws -> String {
  let data = try Data(contentsOf: fixtureRoot.appending(path: path))
  let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  let response = try #require(object["response"])
  let encoded = try JSONSerialization.data(withJSONObject: response)
  return try #require(String(data: encoded, encoding: .utf8))
}

/// A loopback single-user server answering by method and path, then by path.
nonisolated private final class RouteServer: Sendable {
  private let routes = Mutex<[String: HttpResponse]>([:])

  init() {
    route("/.well-known/omnigent.json", .json(ManifestFixtures.localNoAuth))
    route("/v1/info", .json(#"{"single_user":true,"accounts_enabled":false}"#))
    route("/v1/me", .json(#"{"user_id":"local"}"#))
    route("/v1/sessions", .json(#"{"object":"list","data":[],"has_more":false}"#))
  }

  func route(_ path: String, method: String? = nil, _ response: HttpResponse) {
    routes.withLock { $0[(method.map { "\($0) " } ?? "") + path] = response }
  }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    return routes.withLock { $0["\(request.method) \(path)"] ?? $0[path] }
      ?? .json(#"{"detail":"not found"}"#, status: 404)
  }
}

@MainActor
private func connectedStore(
  _ server: RouteServer, sockets: FakeWebSocketTransport = FakeWebSocketTransport()
) async throws -> ConnectionStore {
  let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
  let core = try ClientCore(
    http: http, streams: FakeEventStreamTransport(), sockets: sockets, clock: SystemClock(),
    scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
    entropy: FixedEntropySource(), config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  let store = ConnectionStore(core: core)
  await store.connect(serverURL: "http://127.0.0.1:6767")
  #expect(store.isSignedIn, "phase: \(store.phase)")
  return store
}

@MainActor
private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
  let deadline = ContinuousClock.now + .seconds(10)
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)")
      return
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}

@MainActor
struct SessionEditTests {
  @Test(.timeLimit(.minutes(1))) func pinningUpdatesTheListFromTheAcknowledgement() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions/conv_a", method: "GET",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
    server.route(
      "/v1/sessions/conv_a", method: "PATCH",
      .json(
        #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.pinned":"1"}}"#
      ))
    let store = try await connectedStore(server)
    #expect(await store.sessionList.setPinned("conv_a", true))
    #expect(store.sessionList.session("conv_a")?.isPinned == true)
    #expect(store.sessionList.editError == nil)

    #expect(!(await store.sessionList.rename("conv_a", to: "   ")))
    guard case .Session(let kind, _, _, _, _) = store.sessionList.editError else {
      Issue.record(
        "expected a session error, got \(String(describing: store.sessionList.editError))")
      return
    }
    #expect(kind == .invalidTitle)
  }
}

@MainActor
struct CreationStoreTests {
  private func creationServer() throws -> RouteServer {
    let server = RouteServer()
    server.route("/v1/hosts", .json(try recorded("sessions/SessionCreation--_shared--hosts.json")))
    server.route(
      "/v1/agents", .json(try recorded("sessions/SessionCreation--_shared--agents.json")))
    server.route(
      "/v1/hosts/host_a/harnesses/codex-native/model-options",
      .json(try recorded("sessions/SessionCreation--_shared--model-options.json")))
    server.route(
      "/v1/hosts/host_a/filesystem",
      .json(
        #"{"data":[{"name":"project","path":"/work/project","type":"directory"}],"has_more":false}"#
      ))
    return server
  }

  private let selection = CreationSelection(
    hostId: "host_a", agentId: "ag_codex", workspace: "/work/project", model: nil)

  @Test(.timeLimit(.minutes(1))) func validatesThroughTheCoreAndRetriesOnlyTheFirstMessage()
    async throws
  {
    let server = try creationServer()
    server.route(
      "/v1/sessions", method: "POST",
      .json(
        try recorded(
          "sessions/SessionCreation--201PostsExactExternalHostContractWithoutInitialPrompt.json"),
        status: 201))
    let store = try await connectedStore(server)
    let creation = try #require(store.creation())
    await creation.loadCatalog()
    #expect(creation.catalog.value?.hosts.count == 1)
    await creation.selectionChanged(selection)
    #expect(creation.workspaces.value?.map(\.path) == ["/work/project"])
    #expect(creation.models.value?.first?.value == "provider-model")
    var relative = selection
    relative.workspace = "work"
    #expect(creation.unavailableReason(relative) != nil)
    #expect(creation.unavailableReason(selection) == nil)

    await creation.create(selection, title: "Review", firstMessage: "Hello")
    guard case .created(let sessionID, let firstMessageError) = creation.phase else {
      Issue.record("phase: \(creation.phase)")
      return
    }
    #expect(sessionID == "conv_created")
    #expect(firstMessageError != nil, "the first message has no route")
  }

  @Test(.timeLimit(.minutes(1))) func anUncertainCreationBlocksTheNextUntilAcknowledged()
    async throws
  {
    let server = try creationServer()
    server.route("/v1/sessions", method: "POST", .json("<html>bad gateway</html>", status: 502))
    let store = try await connectedStore(server)
    let creation = try #require(store.creation())
    await creation.create(selection, title: "", firstMessage: "")
    guard case .uncertain = creation.phase else {
      Issue.record("phase: \(creation.phase)")
      return
    }
    #expect(!creation.canCreate)
    await creation.create(selection, title: "", firstMessage: "")
    guard case .uncertain = creation.phase else {
      Issue.record("a second creation must not start: \(creation.phase)")
      return
    }
    creation.acknowledgeUncertain()
    #expect(creation.canCreate)
  }
}

@MainActor
struct WorkspaceStoreTests {
  private let session = "207c660071e248e198c634aec763bb75"

  private func workspaceServer() throws -> RouteServer {
    let server = RouteServer()
    let base = "/v1/sessions/\(session)/resources/environments/default"
    for (path, fixture) in [
      ("\(base)/filesystem", "recorded-filesystem-root.json"),
      ("\(base)/filesystem/src/main.rs", "recorded-file-text.json"),
      ("\(base)/changes", "recorded-changes.json"),
      ("\(base)/diff/src/main.rs", "recorded-diff-modified.json"),
      (base, "recorded-environment-default.json"),
    ] {
      server.route(path, .json(try recorded("workspace/\(fixture)")))
    }
    return server
  }

  @Test(.timeLimit(.minutes(1))) func servesTheWorkspaceViewsFromTheCore() async throws {
    let store = try await connectedStore(try workspaceServer())
    let workspace = try #require(store.workspace(session))
    let page = try await workspace.listDirectory("", after: nil)
    let firstFile = page.entries.firstIndex { !$0.kind.isDirectory } ?? page.entries.endIndex
    #expect(page.entries[firstFile...].allSatisfy { !$0.kind.isDirectory }, "directories first")

    let file = try await workspace.readFile("src/main.rs")
    guard case .text(let preview) = file.preview else {
      Issue.record("preview: \(file.preview)")
      return
    }
    #expect(preview.language == .rust)

    let changes = try await workspace.changes()
    #expect(changes.files.map(\.path) == changes.files.map(\.path).sorted())
    let diff = try await workspace.diff("src/main.rs")
    #expect(diff.added == 2 && diff.removed == 0)
    #expect(!diff.splitRows.isEmpty)

    #expect(workspace.absoluteLocation(of: "src/main.rs") == nil, "root not loaded yet")
    await workspace.loadEnvironment()
    #expect(workspace.absoluteLocation(of: "src/main.rs") == "/workspace/fixture/src/main.rs")

    await #expect(throws: WorkspaceFailure.self) {
      _ = try await workspace.readFile("../etc/passwd")
    }
    do {
      _ = try await workspace.readFile("../etc/passwd")
    } catch {
      #expect(error.kind == .invalidInput)
    }
    do {
      _ = try await workspace.diff("missing.rs")
      Issue.record("a missing diff must fail")
    } catch {
      #expect(error.kind != .invalidInput)
    }
  }
}

/// The next socket the core opens whose URL contains `fragment` (the session-updates socket
/// opens first on every connect).
private func socket(_ sockets: FakeWebSocketTransport, containing fragment: String) async
  -> OpenedWebSocket
{
  while true {
    let opened = await sockets.waitForOpenedSocket()
    if opened.request.url.contains(fragment) { return opened }
  }
}

@MainActor
struct TerminalAttachTests {
  @Test(.timeLimit(.minutes(1)))
  func attachSendsBinaryInputAndDeliversOutputInOrder() async throws {
    let sockets = FakeWebSocketTransport()
    let store = try await connectedStore(RouteServer(), sockets: sockets)
    let terminals = try #require(store.terminals("conv_a"))
    let attach = terminals.attach(
      terminalID: "terminal_codex_main", permissionLevel: 4, hostID: nil)
    var events = attach.events.makeAsyncIterator()
    attach.start()
    #expect(await events.next() == .state(.connecting))
    let opened = await socket(sockets, containing: "/attach")
    #expect(opened.request.url.hasSuffix("/resources/terminals/terminal_codex_main/attach"))
    opened.sink.opened()
    #expect(await events.next() == .state(.attached(readOnly: false)))
    attach.send(Array("ls\r".utf8))
    opened.sink.message(message: .binary(bytes: Data("total 0\r\n".utf8)))
    #expect(await events.next() == .output(Array("total 0\r\n".utf8)))
    try await waitFor("the binary input frame") { !opened.handle.sentBinaries.isEmpty }
    #expect(opened.handle.sentBinaries == [Data("ls\r".utf8)])
    #expect(throws: CoreError.self) { try attach.resize(columns: 0, rows: 10) }
    opened.sink.ended(end: .closed(code: 4404, reason: "terminal not found"))
    guard case .state(.closed(.terminalEnded)) = await events.next() else {
      Issue.record("expected a closed state")
      return
    }
  }
}

/// Records every action it is asked to run.
private final class RecordingPerformer: BrowserActionPerforming {
  var performed: [String] = []
  var failure: (any Error)?

  // swiftlint:disable:next async_without_await
  func perform(_ request: BrowserActionRequest) async throws -> Data {
    performed.append(request.actionId)
    if let failure { throw failure }
    return Data(#"{"ok":true,"data":{"final_url":"https://example.com/"}}"#.utf8)
  }
}

private struct PerformerFailure: Error, CustomStringConvertible {
  var description: String { "engine unavailable" }
}

@MainActor
struct BrowserActionStoreTests {
  private let session = "conv_a"

  private func request(_ id: String) -> BrowserActionRequest {
    BrowserActionRequest(
      sessionId: session, actionId: id, action: "navigate",
      argsJson: #"{"url":"https://example.com"}"#)
  }

  private func server() -> RouteServer {
    let server = RouteServer()
    server.route(
      "/v1/sessions/conv_a/browser/action_claim/baction_won", method: "POST",
      .json(#"{"claimed":true,"claim_token":"tok_1"}"#))
    server.route(
      "/v1/sessions/conv_a/browser/action_claim/baction_lost", method: "POST",
      .json(#"{"claimed":false}"#))
    server.route(
      "/v1/sessions/conv_a/browser/action_result/baction_won", method: "POST",
      .json(#"{"resolved":true}"#, status: 202))
    return server
  }

  @Test(.timeLimit(.minutes(1))) func runsOnlyClaimedActionsAndPostsTheResult() async throws {
    let server = server()
    let store = try await connectedStore(server)
    let actions = try #require(store.browserActions)
    let performer = RecordingPerformer()
    actions.performer = performer

    await actions.handle(request("baction_lost"))
    #expect(performer.performed.isEmpty, "an unclaimed action never runs")
    #expect(actions.actions.last?.phase == .notClaimed)

    await actions.handle(request("baction_won"))
    #expect(performer.performed == ["baction_won"])
    #expect(actions.actions.last?.phase == .delivered(.resolved))

    performer.failure = PerformerFailure()
    server.route(
      "/v1/sessions/conv_a/browser/action_result/baction_won", method: "POST",
      .json(
        #"{"error":{"message":"browser action result requires a matching claim_token"}}"#,
        status: 403))
    await actions.handle(request("baction_won"))
    #expect(actions.actions.last?.performerError?.contains("engine unavailable") == true)
    guard case .failed(.Session(let kind, _, _, _, _)) = actions.actions.last?.phase else {
      Issue.record("phase: \(String(describing: actions.actions.last?.phase))")
      return
    }
    #expect(kind == .browserAction)
    #expect(actions.lastError != nil)
  }

  @Test(.timeLimit(.minutes(1))) func withoutAPerformerNothingIsClaimed() async throws {
    let server = server()
    let store = try await connectedStore(server)
    let actions = try #require(store.browserActions)
    await actions.handle(request("baction_won"))
    #expect(actions.actions.last?.phase == .unhandled)
    let event = try JSONSerialization.jsonObject(with: request("baction_won").eventJSON())
    let object = try #require(event as? [String: Any])
    #expect(object["type"] as? String == "browser.action_request")
    #expect((object["args"] as? [String: Any])?["url"] as? String == "https://example.com")
  }
}
