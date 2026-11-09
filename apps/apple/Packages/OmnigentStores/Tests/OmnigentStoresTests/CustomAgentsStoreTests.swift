import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("Custom agents", .timeLimit(.minutes(1)))
struct CustomAgentsStoreTests {
  private let configJSON =
    #"{"id":"a1","name":"reviewer","version":2,"model":"m","harness":"codex"}"#

  private func agentsStore(_ server: RouteServer) async throws -> CustomAgentsStore {
    let store = try await connectedStore(server)
    return try #require(store.customAgents())
  }

  private func edit(model: String) -> AgentConfigEdit {
    AgentConfigEdit(
      description: "", instructions: "", model: model, harness: "codex", removedMcpServers: [],
      mcpServers: [])
  }

  @Test("Lists the server's and the caller's agents, asking for the caller's scope")
  func listsBothScopes() async throws {
    let server = RouteServer()
    server.route(
      "/v1/agents", .json(#"{"data":[{"id":"a1","name":"reviewer"}],"has_more":false}"#))
    let agents = try await agentsStore(server)
    await agents.load()
    #expect(agents.serverAgents.value?.map(\.id) == ["a1"])
    #expect(agents.myAgents.value?.map(\.id) == ["a1"])
    let queries = server.requests(to: "/v1/agents").map(\.url)
    #expect(queries.filter { $0.contains("scope=user") }.count == 1)
  }

  @Test("A failed list shows its failure in place of the rows")
  func listFailure() async throws {
    let server = RouteServer()
    server.fail("/v1/agents")
    let agents = try await agentsStore(server)
    await agents.load()
    guard case .failed = agents.serverAgents, case .failed = agents.myAgents else {
      Issue.record("expected failures: \(agents.serverAgents), \(agents.myAgents)")
      return
    }
  }

  @Test("Saving the form returns the agent; a refusal keeps the reason for the sheet")
  func createFromTheForm() async throws {
    let server = RouteServer()
    server.route("/v1/agents", method: "POST", .json(#"{"id":"a1","name":"reviewer"}"#))
    let agents = try await agentsStore(server)
    let draft = AgentDraft(
      name: "reviewer", description: "", instructions: "Review", harness: "codex", model: "gpt",
      mcpServers: [])
    #expect(await agents.create(draft)?.id == "a1")
    #expect(agents.error == nil)
    #expect(!agents.isSaving)

    server.fail("/v1/agents", method: "POST", status: 422, detail: "name taken")
    #expect(await agents.create(draft) == nil)
    #expect(agents.error != nil)
    #expect(!agents.isSaving)
  }

  @Test("An empty bundle is refused before anything is sent")
  func importBundle() async throws {
    let server = RouteServer()
    server.route("/v1/agents", method: "POST", .json(#"{"id":"a1","name":"reviewer"}"#))
    let agents = try await agentsStore(server)
    #expect(await agents.importBundle(Data(), filename: "agent.tar.gz") == nil)
    #expect(agents.error?.message == "The bundle is empty.")
    #expect(server.requests(to: "/v1/agents", method: "POST").isEmpty)

    #expect(await agents.importBundle(Data([0x1F, 0x8B]), filename: "agent.tar.gz")?.id == "a1")
    #expect(agents.error == nil, "a success clears the earlier failure")
  }

  @Test("A second write while one is in flight is refused, not queued")
  func writesDoNotOverlap() async throws {
    let server = RouteServer()
    server.route("/v1/agents", method: "POST", .json(#"{"id":"a1","name":"reviewer"}"#))
    let gate = server.hold("/v1/agents", method: "POST")
    let agents = try await agentsStore(server)
    let first = Task { await agents.importBundle(Data([1]), filename: "one.tar.gz") }
    try await eventually("the first write to start") { gate.arrivals == 1 }
    #expect(agents.isSaving)
    #expect(await agents.importBundle(Data([2]), filename: "two.tar.gz") == nil)
    gate.release()
    #expect(await first.value?.id == "a1")
    #expect(gate.arrivals == 1)
  }

  @Test("Editing saves against the loaded revision; nothing loaded saves nothing")
  func editing() async throws {
    let server = RouteServer()
    server.route(
      "/v1/agents/a1/config",
      HttpResponse(
        status: 200, headers: [HttpHeader(name: "ETag", value: "\"rev2\"")],
        body: Data(configJSON.utf8)))
    server.route("/v1/agents/a1", method: "PATCH", .json(configJSON))
    let agents = try await agentsStore(server)
    #expect(!(await agents.save(edit(model: "new"))))
    #expect(server.requests(to: "/v1/agents/a1", method: "PATCH").isEmpty)

    await agents.loadConfig("a1")
    #expect(agents.config.value?.name == "reviewer")
    #expect(await agents.save(edit(model: "new")))
    let patch = try #require(server.requests(to: "/v1/agents/a1", method: "PATCH").first)
    #expect(patch.headers.first { $0.name == "If-Match" }?.value == "\"rev2\"")
  }

  @Test("Someone else's change refuses the save and keeps the form's configuration")
  func staleSave() async throws {
    let server = RouteServer()
    server.route("/v1/agents/a1/config", .json(configJSON))
    server.fail("/v1/agents/a1", method: "PATCH", status: 412, detail: "changed")
    let agents = try await agentsStore(server)
    await agents.loadConfig("a1")
    #expect(!(await agents.save(edit(model: "new"))))
    #expect(agents.error != nil)
    #expect(agents.config.value?.model == "m")
  }

  @Test("A configuration that can't be read reports why")
  func configFailure() async throws {
    let server = RouteServer()
    server.fail("/v1/agents/a1/config", status: 409, detail: "bundle")
    let agents = try await agentsStore(server)
    await agents.loadConfig("a1")
    guard case .failed = agents.config else {
      Issue.record("config: \(agents.config)")
      return
    }
  }

  @Test("Removing drops the row; an agent in use stays until removed with force")
  func removing() async throws {
    let server = RouteServer()
    server.route(
      "/v1/agents", method: "GET",
      .json(
        #"{"data":[{"id":"a1","name":"one"},{"id":"a2","name":"two"}],"has_more":false}"#))
    server.route(
      "/v1/agents/a1", method: "DELETE",
      .json(
        #"{"error":{"code":"agent_in_use","message":"2 session(s) still use 'one'"}}"#,
        status: 409))
    let agents = try await agentsStore(server)
    await agents.load()

    #expect(!(await agents.remove("a1")))
    #expect(agents.inUseMessage?.contains("2 session(s)") == true)
    #expect(agents.myAgents.value?.count == 2, "a refused removal keeps the row")

    server.route("/v1/agents/a1", method: "DELETE", .json(#"{"id":"a1","deleted":true}"#))
    #expect(await agents.remove("a1", force: true))
    #expect(agents.inUseMessage == nil)
    #expect(agents.myAgents.value?.map(\.id) == ["a2"])
    let forced = try #require(server.requests(to: "/v1/agents/a1", method: "DELETE").last)
    #expect(forced.url.contains("force=true"))
  }

  @Test("Removing before the list loaded still succeeds; a failure isn't an in-use notice")
  func removingWithoutAList() async throws {
    let server = RouteServer()
    server.route("/v1/agents/a1", method: "DELETE", .json(#"{"id":"a1","deleted":true}"#))
    let agents = try await agentsStore(server)
    #expect(await agents.remove("a1"))
    #expect(agents.myAgents == .idle)

    server.fail("/v1/agents/a1", method: "DELETE")
    #expect(!(await agents.remove("a1")))
    #expect(agents.inUseMessage == nil)
    #expect(agents.error != nil)
  }

  @Test("A bundle the app couldn't read shows until dismissed, with any in-use notice")
  func messages() async throws {
    let server = RouteServer()
    server.route(
      "/v1/agents/a1", method: "DELETE",
      .json(#"{"error":{"message":"in use"}}"#, status: 409))
    let agents = try await agentsStore(server)
    agents.recordImportFailure("Not a bundle")
    #expect(agents.error?.message == "Not a bundle")
    #expect(!(await agents.remove("a1")))
    #expect(agents.inUseMessage == "in use")
    agents.dismissMessages()
    #expect(agents.error == nil)
    #expect(agents.inUseMessage == nil)
  }
}
