import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("Session tools", .timeLimit(.minutes(1)))
struct SessionToolsStoreTests {
  private let goalPath = "/v1/sessions/conv_a/codex_goal"
  private let goalJSON =
    #"{"goal":{"thread_id":"t","objective":"Ship it","status":"active","token_budget":40000,"tokens_used":1200,"time_used_seconds":180}}"#

  private func tools(_ server: RouteServer) async throws -> SessionToolsStore {
    let store = try await connectedStore(server)
    return try #require(store.conversation("conv_a")).tools
  }

  @Test("Reading the goal marks it loaded, including when there is none")
  func readsTheGoal() async throws {
    let server = RouteServer()
    server.route(goalPath, method: "GET", .json(#"{"goal":null}"#))
    let tools = try await tools(server)
    #expect(!tools.isGoalLoaded)
    await tools.loadGoal()
    #expect(tools.isGoalLoaded)
    #expect(tools.goal == nil)

    server.route(goalPath, method: "GET", .json(goalJSON))
    await tools.loadGoal()
    #expect(tools.goal?.objective == "Ship it")
    #expect(!tools.isBusy)
  }

  @Test("Saving sends the cap, and activates only when asked")
  func savesTheGoal() async throws {
    let server = RouteServer()
    server.route(goalPath, method: "PUT", .json(goalJSON))
    let tools = try await tools(server)
    #expect(await tools.saveGoal(objective: "Ship it", tokenBudget: 40000, activate: true))
    #expect(await tools.saveGoal(objective: "Ship it", tokenBudget: nil, activate: false))
    #expect(tools.goal?.objective == "Ship it")
    let writes = server.requests(to: goalPath, method: "PUT")
    #expect(writes.count == 2)
    #expect(try server.body(of: writes[0])["status"] as? String == "active")
    #expect(try server.body(of: writes[1])["status"] == nil)
  }

  @Test("Pausing and clearing follow the server's answer")
  func pausesAndClears() async throws {
    let server = RouteServer()
    server.route(goalPath, method: "PUT", .json(goalJSON))
    server.route(
      "\(goalPath)/status", method: "PATCH",
      .json(goalJSON.replacingOccurrences(of: "active", with: "paused")))
    server.route(goalPath, method: "DELETE", .json(#"{"cleared":true}"#))
    let tools = try await tools(server)
    #expect(await tools.saveGoal(objective: "Ship it", tokenBudget: nil, activate: true))
    await tools.setGoalActive(false)
    #expect(tools.goal?.status == "paused")
    await tools.clearGoal()
    #expect(tools.goal == nil)
    #expect(tools.isGoalLoaded)
    #expect(tools.lastError == nil, "\(String(describing: tools.lastError))")
  }

  @Test("A failed request keeps the goal shown, and the next success clears the failure")
  func failuresAreKept() async throws {
    let server = RouteServer()
    server.route(goalPath, method: "PUT", .json(goalJSON))
    let tools = try await tools(server)
    #expect(await tools.saveGoal(objective: "Ship it", tokenBudget: nil, activate: true))

    server.fail(goalPath, method: "PUT")
    #expect(!(await tools.saveGoal(objective: "Other", tokenBudget: nil, activate: false)))
    #expect(tools.goal?.objective == "Ship it")
    #expect(tools.lastError != nil)
    #expect(!tools.isBusy)

    server.route(goalPath, method: "PUT", .json(goalJSON))
    #expect(await tools.saveGoal(objective: "Ship it", tokenBudget: nil, activate: false))
    #expect(tools.lastError == nil)

    server.fail(goalPath, method: "DELETE")
    await tools.clearGoal()
    #expect(tools.goal != nil, "a refused clear keeps the goal")
    tools.dismissError()
    #expect(tools.lastError == nil)
    tools.dismissError()
  }

  @Test("Plan mode is sent as a collaboration mode; a refusal is kept")
  func planMode() async throws {
    let server = RouteServer()
    let path = "/v1/sessions/conv_a"
    server.route(
      path, method: "PATCH",
      .json(
        #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.codex_native.collaboration_mode":"plan"}}"#
      ))
    let tools = try await tools(server)
    await tools.setPlanMode(true)
    await tools.setPlanMode(false)
    #expect(tools.lastError == nil, "\(String(describing: tools.lastError))")
    let writes = server.requests(to: path, method: "PATCH")
    #expect(try server.body(of: writes[0])["collaboration_mode"] as? String == "plan")
    #expect(try server.body(of: writes[1])["collaboration_mode"] as? String == "default")

    server.fail(path, method: "PATCH")
    await tools.setPlanMode(true)
    #expect(tools.lastError != nil)
  }

  @Test("A side chat that can't be created throws, leaving the store's failure alone")
  func sideChatFailure() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions/conv_a", method: "GET")
    let tools = try await tools(server)
    await #expect(throws: CoreError.self) { try await tools.createSideChat(text: "hello") }
    #expect(tools.lastError == nil)
    #expect(!tools.isBusy)
  }

  @Test("A side chat starts from the session and sends its first message")
  func sideChat() async throws {
    let server = RouteServer()
    let source =
      #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4,"harness":"claude-native","runner_id":"run_1","runner_online":true,"host_id":"host_1"}"#
    let side =
      #"{"id":"conv_side","status":"idle","created_at":2,"permission_level":4,"runner_id":"run_1","labels":{"omnigent.side_chat":"1"}}"#
    server.route("/v1/sessions/conv_a", method: "GET", .json(source))
    server.route("/v1/sessions/conv_a/fork", method: "POST", .json(side))
    server.route("/v1/sessions/conv_side", .json(side))
    server.route(
      "/v1/sessions/conv_side/events", method: "POST",
      .json(#"{"queued":true,"item_id":"item_1"}"#, status: 202))
    let tools = try await tools(server)
    let created = try await tools.createSideChat(text: "hello")
    #expect(created.sessionId == "conv_side")
    #expect(server.requests(to: "/v1/sessions/conv_side/events", method: "POST").count == 1)
  }

  @Test("A failed tree read keeps the last good tree; a read in flight isn't repeated")
  func agentTree() async throws {
    let server = RouteServer()
    let snapshot = #"{"id":"conv_a","status":"idle","created_at":1,"permission_level":4}"#
    server.route("/v1/sessions/conv_a", .json(snapshot))
    server.route(
      "/v1/sessions/conv_a/items", .json(#"{"object":"list","data":[],"has_more":false}"#))
    server.route("/v1/sessions/conv_a/child_sessions", .json(#"{"data":[],"has_more":false}"#))
    let gate = server.hold("/v1/sessions/conv_a/child_sessions")
    let tools = try await tools(server)
    let first = Task { await tools.loadAgentTree() }
    try await eventually("the tree read to start") { gate.arrivals > 0 }
    let arrivals = gate.arrivals
    await tools.loadAgentTree()
    #expect(gate.arrivals == arrivals, "the second read returned without a request")
    gate.release()
    await first.value
    let tree = try #require(tools.agentTree)
    #expect(tools.agentTreeError == nil)

    server.dropConnection("/v1/sessions/conv_a/child_sessions")
    await tools.loadAgentTree()
    #expect(tools.agentTreeError != nil)
    #expect(tools.agentTree == tree)

    let healthy = RouteServer()
    healthy.route("/v1/sessions/conv_a", .json(snapshot))
    healthy.route(
      "/v1/sessions/conv_a/items", .json(#"{"object":"list","data":[],"has_more":false}"#))
    healthy.route("/v1/sessions/conv_a/child_sessions", .json(#"{"data":[],"has_more":false}"#))
    let recovered = try await self.tools(healthy)
    await recovered.loadAgentTree()
    #expect(recovered.agentTreeError == nil)
  }
}
