import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import Synchronization
import Testing

@testable import OmnigentStores

/// A loopback single-user server for the pages beside the sessions.
nonisolated private final class PagesServer: Sendable {
  private let routes = Mutex<[String: HttpResponse]>([:])
  private let requests = Mutex<[String]>([])

  static let task =
    #"{"id":"t1","name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"a1","timezone":"UTC","state":"active","next_run_at":"2026-11-05T09:00:00Z","updated_at":1}"#

  init() {
    route("/.well-known/omnigent.json", .json(ManifestFixtures.localNoAuth))
    route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"automations_enabled":true,"features":{"usage_page":false}}"#
      ))
    route("/v1/me", .json(#"{"user_id":"local"}"#))
    route(
      "/v1/sessions",
      .json(
        #"{"object":"list","data":[{"id":"conv_a","status":"idle","created_at":1,"updated_at":5,"owner":"local","permission_level":4,"comments_count":1}],"has_more":false}"#
      ))
    route("/v1/scheduled-tasks", method: "GET", .json(#"{"scheduled_tasks":[\#(Self.task)]}"#))
    route("/v1/scheduled-tasks/t1", method: "PATCH", .json(Self.task))
    route(
      "/v1/sessions/conv_a/comments",
      .json(
        #"[{"id":"c1","conversation_id":"conv_a","path":"a.rs","start_index":0,"end_index":1,"body":"Why?","status":"draft","created_at":3,"updated_at":3,"created_by":"bob@x"}]"#
      ))
    route(
      "/v1/sessions/conv_a",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
  }

  func route(_ path: String, method: String? = nil, _ response: HttpResponse) {
    routes.withLock { $0[(method.map { "\($0) " } ?? "") + path] = response }
  }

  var writes: [String] { requests.withLock { $0 } }

  func respond(_ request: HttpRequest) -> HttpResponse {
    let path = URLComponents(string: request.url)?.path ?? ""
    if request.method != "GET" { requests.withLock { $0.append("\(request.method) \(path)") } }
    return routes.withLock { $0["\(request.method) \(path)"] ?? $0[path] }
      ?? .json(#"{"detail":"not found"}"#, status: 404)
  }
}

@MainActor
struct PagesStoreTests {
  private func connected(_ server: PagesServer) async throws -> ConnectionStore {
    let http = FakeHttpTransport { request throws(TransportError) in server.respond(request) }
    let core = try ClientCore(
      http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    let store = ConnectionStore(core: core)
    await store.connect(serverURL: "http://127.0.0.1:6767")
    #expect(store.isSignedIn, "phase: \(store.phase)")
    let deadline = ContinuousClock.now + .seconds(10)
    while !store.sessionList.isLoaded, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    return store
  }

  @Test(.timeLimit(.minutes(1)))
  func offeredPagesAndAutomationWrites() async throws {
    let server = PagesServer()
    let pages = try #require(try await connected(server).pages)
    #expect(await pages.loadOffered() == nil)
    #expect(pages.offered?.automations == true)
    #expect(pages.offered?.usage == false)

    await pages.loadAutomations()
    #expect(pages.automations.value?.map(\.scheduleText) == ["Every day at 9:00 AM"])
    #expect(await pages.setAutomationPaused("t1", true))
    #expect(pages.busyAutomationIDs.isEmpty)
    #expect(server.writes == ["PATCH /v1/scheduled-tasks/t1"])

    // A refused write is kept for the page and leaves the list as it was.
    #expect(!(await pages.deleteAutomation("t1")))
    #expect(pages.automationError != nil)
    #expect(pages.automations.value?.count == 1)
    pages.dismissAutomationError()
    #expect(pages.automationError == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func runHistoryAndEditsOfTheSavedAutomation() async throws {
    let server = PagesServer()
    server.route(
      "/v1/scheduled-tasks/t1/runs",
      .json(
        #"{"runs":[{"id":"r1","scheduled_task_id":"t1","status":"failed","scheduled_at":10,"error_code":"host_offline"}]}"#
      ))
    let pages = try #require(try await connected(server).pages)
    await pages.loadAutomationRuns("t1")
    let run = try #require(pages.automationRuns["t1"]?.value?.first)
    #expect(run.failureStage == "Host")
    #expect(run.failureReason == "The host was offline.")
    await pages.loadAutomationRuns("missing")
    #expect(pages.automationRuns["missing"]?.value == nil)

    await pages.loadAutomations()
    let saved = try #require(pages.automations.value?.first)
    let draft = AutomationDraft(
      name: saved.name, prompt: saved.prompt, rrule: saved.rrule, agentId: saved.agentId,
      timezone: saved.timezone, continuesSession: nil)
    #expect(await pages.saveAutomation(draft, editing: saved))
    #expect(server.writes == ["PATCH /v1/scheduled-tasks/t1"])
  }

  @Test(.timeLimit(.minutes(1)))
  func commentsAreReadOnceAndSeenOnThisDevice() async throws {
    let server = PagesServer()
    let store = try await connected(server)
    let pages = try #require(store.pages)
    let key = "PagesStoreTests.seen.\(UUID().uuidString)"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    pages.bindSeenComments(key: key)
    await pages.refreshComments(Array(store.sessionList.sessionsByID.values))
    #expect(pages.unseenComments(viewerID: nil).map(\.id) == ["c1"])
    #expect(pages.unseenComments(viewerID: "bob@x").isEmpty)
    pages.markCommentSeen("c1")
    #expect(pages.unseenComments(viewerID: nil).isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func replyStatesFollowTheSend() async throws {
    let server = PagesServer()
    let store = try await connected(server)
    let pages = try #require(store.pages)
    let session = try #require(store.sessionList.session("conv_a"))
    server.route(
      "/v1/sessions/conv_a/events", method: "POST",
      .json(#"{"detail":"blocked"}"#, status: 409))
    #expect(!(await pages.reply("Ship it", to: session)))
    guard case .failed = pages.replies["conv_a"] else {
      Issue.record("expected a failure: \(String(describing: pages.replies["conv_a"]))")
      return
    }
    server.route(
      "/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    #expect(await pages.reply("Ship it", to: session))
    #expect(pages.replies["conv_a"] == .sent(since: 5))
    var later = session
    later.updatedAt = 9
    pages.settleReplies(["conv_a": later])
    #expect(pages.replies["conv_a"] == nil)
  }

  @Test(.timeLimit(.minutes(1)))
  func finishedTurnsNotifyWithTheReplyPreview() async throws {
    let server = PagesServer()
    server.route(
      "/v1/sessions/conv_a/items",
      .json(
        #"{"data":[{"id":"i1","type":"message","role":"assistant","content":[{"type":"output_text","text":"Fixed the badge.\nAll tests pass."}]}],"has_more":false}"#
      ))
    let store = try await connected(server)
    let notifications = try #require(store.notifications)
    let idle = "Agent finished and is ready for your input."
    notifications.notify(
      AttentionNotification(sessionId: "conv_a", kind: .completed, title: nil, body: idle))
    notifications.notify(
      AttentionNotification(
        sessionId: "conv_a", kind: .approval, title: nil, body: "Agent is asking for your input."))
    notifications.notify(
      AttentionNotification(sessionId: "conv_gone", kind: .completed, title: nil, body: idle))
    let (taken, failures) = await notifications.takeWithReplyPreviews()
    #expect(
      taken.map(\.body) == [
        "Fixed the badge.\nAll tests pass.", "Agent is asking for your input.", idle,
      ])
    // The unreadable one still notifies, with the default body.
    #expect(failures.count == 1)
    #expect(notifications.pending.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func canvasLaysOutSavesAndResetsCards() async throws {
    let server = PagesServer()
    let store = try await connected(server)
    let canvas = try #require(store.canvas)
    let key = "PagesStoreTests.canvas.\(UUID().uuidString)"
    defer {
      UserDefaults.standard.removeObject(forKey: "\(key).positions")
      UserDefaults.standard.removeObject(forKey: "\(key).board")
    }
    canvas.bind(key: key)
    await canvas.load(viewerID: "local")
    #expect(canvas.sessions.value?.map(\.id) == ["conv_a"])
    canvas.relayout(projects: [], viewerID: "local")
    #expect(canvas.positions["conv_a"] == CanvasPosition(x: 0, y: 0))
    #expect(canvas.boardOf["conv_a"] == mainCanvasId())
    // A drop snaps to the grid and survives a new store on the same key.
    canvas.move("conv_a", left: 70, top: 50)
    #expect(canvas.positions["conv_a"] == CanvasPosition(x: 64, y: 64))
    let reopened = try #require(try await connected(server).canvas)
    reopened.bind(key: key)
    #expect(reopened.saved["conv_a"] == CanvasPosition(x: 64, y: 64))
    canvas.select(board: "p1")
    canvas.select(board: mainCanvasId())
    canvas.resetLayout()
    #expect(canvas.positions["conv_a"] == CanvasPosition(x: 0, y: 0))
  }
}
