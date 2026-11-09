import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

private let automation =
  #"{"id":"t1","name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"a1","timezone":"UTC","state":"active"}"#
private let automationList = HttpResponse.json(#"{"scheduled_tasks":[\#(automation)]}"#)
private let usageReport = HttpResponse.json(
  #"{"object":"usage_report","cost_today":1.0,"daily_costs":[{"day":"2026-11-04","cost_usd":1.0}],"sessions":[]}"#
)
private let commentJSON =
  #"{"id":"c1","conversation_id":"conv_a","path":"a.rs","start_index":0,"end_index":1,"body":"Why?","status":"draft","created_at":3,"created_by":"bob"}"#
private let reply = HttpResponse.json(
  #"{"data":[{"id":"i3","type":"message","role":"assistant","content":[{"type":"output_text","text":"All tests pass."}]}],"has_more":false}"#
)

/// A listed session with only what the Inbox reads.
private func listed(
  _ id: String = "conv_a", updatedAt: Int64 = 5, status: SessionListStatus = .idle,
  comments: UInt64 = 0,
  isArchived: Bool = false
) -> SessionSummary {
  var session = SessionSummary(
    id: id, title: id, preview: "", status: status, pendingRequests: 0, isReadOnly: false,
    updatedAt: updatedAt, workspace: "", agentName: "", isPinned: false, isArchived: isArchived,
    permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true, canArchive: true)
  session.commentsCount = comments
  return session
}

@MainActor
private func connectedPages(_ server: RouteServer = RouteServer()) async throws -> PagesStore {
  let connection = try await connectedStore(server)
  return try #require(connection.pages)
}

private func isFailed<Value>(_ load: CreationLoad<Value>?) -> Bool {
  if case .failed = load { return true }
  return false
}

/// The pages beside the sessions: each failure stays with what it failed to load.
@MainActor
@Suite("Page reads and writes", .timeLimit(.minutes(1)))
struct PagesStoreLoadTests {
  private func draft() -> AutomationDraft {
    AutomationDraft(
      name: "Standup", prompt: "Summarize", rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      agentId: "a1", timezone: "UTC", continuesSession: nil, hostId: "host_a", workspace: "/w",
      runsInSandbox: false, projectId: nil, sendsOverrides: false, modelOverride: nil,
      reasoningEffort: nil, permissionMode: nil)
  }

  @Test("Pages the server won't describe stay unoffered, and the failure is returned")
  func offeredFailure() async throws {
    let server = RouteServer()
    let pages = try await connectedPages(server)
    server.fail("/v1/info")
    #expect(await pages.loadOffered() != nil)
    #expect(pages.offered == nil)
  }

  @Test("A failed read of the automations shows the failure; a reload that works replaces it")
  func automationsRead() async throws {
    let server = RouteServer()
    server.fail("/v1/scheduled-tasks", method: "GET")
    let pages = try await connectedPages(server)
    await pages.loadAutomations()
    #expect(isFailed(pages.automations))

    server.route("/v1/scheduled-tasks", method: "GET", automationList)
    await pages.loadAutomations()
    #expect(pages.automations.value?.map(\.id) == ["t1"])
  }

  @Test("A reload keeps the automations on screen until it lands")
  func automationsReload() async throws {
    let server = RouteServer()
    server.route("/v1/scheduled-tasks", method: "GET", automationList)
    let pages = try await connectedPages(server)
    await pages.loadAutomations()

    let gate = server.hold("/v1/scheduled-tasks", method: "GET")
    async let reload: Void = pages.loadAutomations()
    try await eventually("the reload") { gate.arrivals > 0 }
    #expect(pages.automations.value?.map(\.id) == ["t1"])
    gate.release()
    await reload
  }

  @Test("Creating an automation reloads the list; a refusal keeps the reason")
  func createsAutomation() async throws {
    let server = RouteServer()
    server.route("/v1/scheduled-tasks", method: "GET", automationList)
    server.fail("/v1/scheduled-tasks", method: "POST", status: 422, detail: "bad schedule")
    let pages = try await connectedPages(server)
    #expect(await !pages.saveAutomation(draft(), editing: nil))
    #expect(pages.automationError?.message.contains("bad schedule") == true)
    #expect(pages.automations == .idle, "nothing changed, so nothing is re-read")

    server.route("/v1/scheduled-tasks", method: "POST", .json(automation, status: 201))
    #expect(await pages.saveAutomation(draft(), editing: nil))
    #expect(pages.automationError == nil)
    #expect(pages.automations.value?.count == 1)
  }

  @Test("One automation takes one write at a time; other automations aren't held up")
  func oneWritePerAutomation() async throws {
    let server = RouteServer()
    server.route("/v1/scheduled-tasks", method: "GET", automationList)
    server.route("/v1/scheduled-tasks/t1/run", method: "POST", .json(#"{"triggered":true}"#))
    server.route("/v1/scheduled-tasks/t2/run", method: "POST", .json(#"{"triggered":true}"#))
    let gate = server.hold("/v1/scheduled-tasks/t1/run", method: "POST")
    let pages = try await connectedPages(server)

    async let first = pages.runAutomation("t1")
    try await eventually("the run") { gate.arrivals > 0 }
    #expect(pages.busyAutomationIDs == ["t1"])
    #expect(await !pages.runAutomation("t1"), "a second click is ignored")
    #expect(await pages.runAutomation("t2"))
    gate.release()
    #expect(await first)
    #expect(pages.busyAutomationIDs.isEmpty)
    #expect(server.requests(to: "/v1/scheduled-tasks/t1/run").count == 1)
  }

  @Test("A failed run history is kept for that automation; a reload keeps the runs on screen")
  func runHistory() async throws {
    let server = RouteServer()
    let path = "/v1/scheduled-tasks/t1/runs"
    server.fail(path)
    let pages = try await connectedPages(server)
    await pages.loadAutomationRuns("t1")
    #expect(isFailed(pages.automationRuns["t1"]))

    server.route(
      path,
      .json(#"{"runs":[{"id":"r1","scheduled_task_id":"t1","status":"failed","scheduled_at":10}]}"#)
    )
    await pages.loadAutomationRuns("t1")
    #expect(pages.automationRuns["t1"]?.value?.map(\.id) == ["r1"])
    let gate = server.hold(path)
    async let reload: Void = pages.loadAutomationRuns("t1")
    try await eventually("the reload") { gate.arrivals > 0 }
    #expect(pages.automationRuns["t1"]?.value?.map(\.id) == ["r1"])
    gate.release()
    await reload
  }

  @Test("Projects read until they load, then never again")
  func automationProjects() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions/projects")
    server.fail("/v1/projects")
    let pages = try await connectedPages(server)
    await pages.loadAutomationProjects()
    #expect(isFailed(pages.automationProjects))

    server.route("/v1/sessions/projects", .json("[]"))
    server.route("/v1/projects", .json(#"{"object":"list","data":[],"has_more":false}"#))
    await pages.loadAutomationProjects()
    #expect(pages.automationProjects.value != nil)
    let reads = server.requests().count
    await pages.loadAutomationProjects()
    #expect(server.requests().count == reads)
  }

  @Test("The agents and hosts read until they load, then never again")
  func automationCatalog() async throws {
    let server = try creationRoutes()
    server.fail("/v1/agents")
    let pages = try await connectedPages(server)
    await pages.loadAutomationCatalog()
    #expect(isFailed(pages.automationCatalog))

    server.route(
      "/v1/agents", .json(try recorded("sessions/SessionCreation--_shared--agents.json")))
    await pages.loadAutomationCatalog()
    #expect(pages.automationCatalog.value?.agents.isEmpty == false)
    let reads = server.requests(to: "/v1/agents").count
    await pages.loadAutomationCatalog()
    #expect(server.requests(to: "/v1/agents").count == reads)
  }

  @Test("Models read per agent and host; a failure retries, a loaded or loading read doesn't")
  func automationModels() async throws {
    let server = try creationRoutes()
    let options = "/v1/hosts/host_a/harnesses/codex-native/model-options"
    let pages = try await connectedPages(server)
    await pages.loadAutomationCatalog()
    let agent = try #require(
      pages.automationCatalog.value?.agents.first { $0.harness == "codex-native" })
    let key = PagesStore.modelsKey(agentID: agent.id, hostID: "host_a")

    let working = server.respond(
      HttpRequest(method: "GET", url: "http://127.0.0.1:6767\(options)", headers: [], body: nil))
    server.fail(options)
    await pages.loadAutomationModels(agentID: agent.id, hostID: "host_a")
    #expect(isFailed(pages.automationModels[key]))

    server.route(options, working)
    let gate = server.hold(options)
    async let read: Void = pages.loadAutomationModels(agentID: agent.id, hostID: "host_a")
    try await eventually("the retry") { gate.arrivals > 0 }
    await pages.loadAutomationModels(agentID: agent.id, hostID: "host_a")
    #expect(gate.arrivals == 1, "already loading")
    gate.release()
    await read
    #expect(pages.automationModels[key]?.value?.isEmpty == false)
    await pages.loadAutomationModels(agentID: agent.id, hostID: "host_a")
    #expect(gate.arrivals == 1, "already loaded")
  }

  @Test("Spend shows its failure; a reload keeps the report on screen")
  func usage() async throws {
    let server = RouteServer()
    server.fail("/v1/usage")
    let pages = try await connectedPages(server)
    await pages.loadUsage()
    #expect(isFailed(pages.usage))

    server.route("/v1/usage", usageReport)
    await pages.loadUsage()
    #expect(pages.usage.value != nil)
    let gate = server.hold("/v1/usage")
    async let reload: Void = pages.loadUsage()
    try await eventually("the reload") { gate.arrivals > 0 }
    #expect(pages.usage.value != nil)
    gate.release()
    await reload
  }
}

/// The Inbox's comments, latest replies and reply states.
@MainActor
@Suite("The Inbox", .timeLimit(.minutes(1)))
struct InboxReadTests {
  @Test(
    "Comments re-read only when a count changes, retry after a failure, and leave with the session")
  func commentReads() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a/comments"
    server.fail(path)
    let pages = try await connectedPages(server)

    await pages.refreshComments([listed(comments: 1)])
    #expect(pages.commentErrors["conv_a"] != nil)
    #expect(!pages.isReadingInbox)

    server.route(path, .json("[\(commentJSON)]"))
    await pages.refreshComments([listed(comments: 1)])
    #expect(pages.comments["conv_a"]?.map(\.id) == ["c1"])
    #expect(pages.commentErrors["conv_a"] == nil, "the retry clears the failure")

    let reads = server.requests(to: path).count
    await pages.refreshComments([listed(comments: 1)])
    #expect(server.requests(to: path).count == reads, "same count, no read")
    await pages.refreshComments([listed(comments: 2)])
    #expect(server.requests(to: path).count == reads + 1)

    await pages.refreshComments([listed(comments: 1, isArchived: true)])
    #expect(pages.comments["conv_a"] == nil)

    server.fail(path)
    await pages.refreshComments([listed(comments: 3)])
    #expect(pages.commentErrors["conv_a"] != nil)
    await pages.refreshComments([])
    #expect(pages.commentErrors["conv_a"] == nil)
  }

  @Test("A session listed twice is read once")
  func duplicateRows() async throws {
    let server = RouteServer()
    server.route("/v1/sessions/conv_a/comments", .json("[\(commentJSON)]"))
    server.route("/v1/sessions/conv_a/items", reply)
    let pages = try await connectedPages(server)
    await pages.refreshComments([listed(comments: 1), listed(comments: 9)])
    await pages.refreshLatestOutputs([listed(), listed(updatedAt: 9)])
    #expect(server.requests(to: "/v1/sessions/conv_a/comments").count == 1)
    #expect(pages.latestOutputs["conv_a"]?.preview == "All tests pass.")
  }

  @Test("Latest replies re-read on new activity, retry after a failure, and leave with the session")
  func latestOutputs() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a/items"
    server.fail(path)
    let pages = try await connectedPages(server)
    await pages.refreshLatestOutputs([listed()])
    #expect(pages.outputErrors["conv_a"] != nil)

    server.route(path, reply)
    await pages.refreshLatestOutputs([listed()])
    #expect(pages.outputErrors["conv_a"] == nil)
    #expect(pages.latestOutputs["conv_a"]?.preview == "All tests pass.")

    let reads = server.requests(to: path).count
    await pages.refreshLatestOutputs([listed()])
    #expect(server.requests(to: path).count == reads, "no new activity, no read")
    await pages.refreshLatestOutputs([listed(updatedAt: 6)])
    #expect(server.requests(to: path).count == reads + 1)

    await pages.refreshLatestOutputs([])
    #expect(pages.latestOutputs.isEmpty)

    server.fail(path)
    await pages.refreshLatestOutputs([listed(updatedAt: 7)])
    #expect(pages.outputErrors["conv_a"] != nil)
    await pages.refreshLatestOutputs([])
    #expect(pages.outputErrors.isEmpty)
  }

  @Test("Seen comments are remembered per server and user, and survive a restart")
  func seenComments() async throws {
    let core = try #require(try await connectedStore(RouteServer()).core)
    let suite = "seen-comments-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let pages = PagesStore(core: core, defaults: defaults)
    pages.markCommentSeen("before binding")
    #expect(defaults.stringArray(forKey: "server-a") == nil, "nothing to save it under yet")
    pages.bindSeenComments(key: "server-a")
    #expect(pages.seenCommentIDs.isEmpty)
    pages.markCommentSeen("c2")
    pages.markCommentSeen("c1")
    pages.markCommentSeen("c1")
    #expect(defaults.stringArray(forKey: "server-a") == ["c1", "c2"])

    pages.bindSeenComments(key: "server-a")
    #expect(pages.seenCommentIDs == ["c1", "c2"], "binding the same key again changes nothing")

    let restarted = PagesStore(core: core, defaults: defaults)
    restarted.bindSeenComments(key: "server-a")
    #expect(restarted.seenCommentIDs == ["c1", "c2"])
    restarted.bindSeenComments(key: "server-b")
    #expect(restarted.seenCommentIDs.isEmpty, "another account starts unread")
  }

  @Test("A reply in flight isn't sent twice; editing the draft forgets the state")
  func replies() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions/conv_a",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
    server.route(
      "/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    let gate = server.hold("/v1/sessions/conv_a/events", method: "POST")
    let pages = try await connectedPages(server)

    async let first = pages.reply("Ship it", to: listed())
    try await eventually("the reply") { gate.arrivals > 0 }
    #expect(pages.replies["conv_a"] == .sending)
    #expect(await !pages.reply("Ship it", to: listed()))
    gate.release()
    #expect(await first)
    #expect(gate.arrivals == 1)

    pages.clearReply("conv_a")
    #expect(pages.replies["conv_a"] == nil)
    pages.clearReply("conv_a")
    #expect(pages.replies.isEmpty)
  }

  @Test("A sent reply settles only once the session moved on and no turn is running")
  func settlesReplies() async throws {
    let server = RouteServer()
    server.route(
      "/v1/sessions/conv_a",
      .json(#"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#))
    server.route(
      "/v1/sessions/conv_a/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    let pages = try await connectedPages(server)
    #expect(await pages.reply("Ship it", to: listed(updatedAt: 5)))

    pages.settleReplies([:])
    #expect(pages.replies["conv_a"] == .sent(since: 5), "not listed")
    pages.settleReplies(["conv_a": listed(updatedAt: 5)])
    #expect(pages.replies["conv_a"] == .sent(since: 5), "no new activity")
    pages.settleReplies(["conv_a": listed(updatedAt: 6, status: .running)])
    #expect(pages.replies["conv_a"] == .sent(since: 5), "the agent is still answering")
    pages.settleReplies(["conv_a": listed(updatedAt: 6)])
    #expect(pages.replies["conv_a"] == nil)
  }
}
