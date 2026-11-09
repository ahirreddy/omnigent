import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// A created session answering every read the first message needs.
private let createdSnapshot =
  #"{"id":"conv_created","status":"idle","created_at":1,"permission_level":4}"#

private let newSessionSelection = CreationSelection(
  hostId: "host_a", agentId: "ag_codex", workspace: "/work/project", model: nil)

private func creationRoutes() throws -> RouteServer {
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
  server.route("/v1/sessions/conv_created", .json(createdSnapshot))
  server.route("/v1/sessions/conv_created/items", .json(#"{"data":[],"has_more":false}"#))
  return server
}

private func acceptCreation(_ server: RouteServer) throws {
  server.route(
    "/v1/sessions", method: "POST",
    .json(
      try recorded(
        "sessions/SessionCreation--201PostsExactExternalHostContractWithoutInitialPrompt.json"),
      status: 201))
}

@MainActor
private func loadedCreation(_ server: RouteServer) async throws -> CreationStore {
  let store = try await connectedStore(server)
  let creation = try #require(store.creation())
  await creation.loadCatalog()
  await creation.selectionChanged(newSessionSelection)
  return creation
}

@MainActor
private func createdError(_ creation: CreationStore) -> CoreError? {
  guard case .created(_, let error) = creation.phase else {
    Issue.record("phase: \(creation.phase)")
    return nil
  }
  return error
}

/// The new-session form's loads, each failing alone.
@MainActor
@Suite("New session form", .timeLimit(.minutes(1)))
struct CreationFormTests {
  private let selection = newSessionSelection

  @Test("A failed catalog shows; a refresh keeps the list until it answers")
  func catalogFails() async throws {
    let server = try creationRoutes()
    let creation = try await loadedCreation(server)
    #expect(creation.catalog.value != nil)
    let gate = server.hold("/v1/agents")
    let refreshing = Task { await creation.refreshCatalog() }
    try await eventually("the refresh") { gate.arrivals == 1 }
    #expect(creation.catalog.value != nil, "what's on screen stays while it reads")
    server.fail("/v1/agents")
    gate.release()
    await refreshing.value
    guard case .failed = creation.catalog else {
      Issue.record("catalog: \(creation.catalog)")
      return
    }
    #expect(creation.unavailableReason(selection) == "The host and agent list has not loaded.")
    await creation.loadCatalog()
    guard case .failed = creation.catalog else {
      Issue.record("catalog: \(creation.catalog)")
      return
    }
  }

  @Test("A failed folder or model read shows on that field alone")
  func selectionReadsFail() async throws {
    let server = try creationRoutes()
    server.fail("/v1/hosts/host_a/filesystem")
    let creation = try await loadedCreation(server)
    guard case .failed = creation.workspaces else {
      Issue.record("workspaces: \(creation.workspaces)")
      return
    }
    #expect(creation.models.value != nil)

    server.route(
      "/v1/hosts/host_a/filesystem", .json(#"{"data":[],"has_more":false}"#))
    server.fail("/v1/hosts/host_a/harnesses/codex-native/model-options")
    await creation.selectionChanged(selection)
    #expect(creation.workspaces.value?.isEmpty == true)
  }

  @Test("A newer selection supersedes an older one's folders and models")
  func supersededSelection() async throws {
    let server = try creationRoutes()
    let creation = try await loadedCreation(server)
    let gate = server.hold("/v1/hosts/host_a/filesystem")
    let older = Task { await creation.selectionChanged(selection) }
    try await eventually("the older read") { gate.arrivals == 1 }
    var other = selection
    other.hostId = "host_b"
    await creation.selectionChanged(other)
    let shown = creation.workspaces
    gate.release()
    await older.value
    #expect(creation.workspaces == shown, "the older answer is dropped")
  }

  @Test("A newer folder supersedes an older one's worktrees, and a failure shows")
  func worktrees() async throws {
    let server = try creationRoutes()
    server.route(
      "/v1/hosts/host_a/worktrees",
      .json(#"{"object":"list","data":[{"path":"/r","branch":"main","is_main":true}]}"#))
    let gate = server.hold("/v1/hosts/host_a/worktrees")
    let creation = try await loadedCreation(server)
    let older = Task { await creation.folderChanged(hostID: "host_a", path: "/r") }
    try await eventually("the read") { gate.arrivals == 1 }
    #expect(creation.worktrees == .loading)
    await creation.folderChanged(hostID: "", path: "/r")
    #expect(creation.worktrees == .idle, "no host, nothing to read")
    gate.release()
    await older.value
    #expect(creation.worktrees == .idle)

    server.fail("/v1/hosts/host_a/worktrees")
    await creation.folderChanged(hostID: "host_a", path: " /r ")
    guard case .failed = creation.worktrees else {
      Issue.record("worktrees: \(creation.worktrees)")
      return
    }
  }

  @Test("Project defaults and the folder browser report why they couldn't be read")
  func browseFailures() async throws {
    let server = try creationRoutes()
    let creation = try await loadedCreation(server)
    let project = ProjectSummary(id: "p1", name: "Alpha", icon: nil)
    guard case .failure = await creation.projectSettings(project) else {
      Issue.record("a missing project has no settings")
      return
    }
    server.route(
      "/v1/projects/p1", .json(#"{"id":"p1","name":"Alpha","config":{"agent_id":"ag_codex"}}"#))
    guard case .success(let settings) = await creation.projectSettings(project) else {
      Issue.record("the project has settings")
      return
    }
    #expect(settings.agentId == "ag_codex")
    guard case .failure = await creation.directory(hostID: "host_a", path: "relative") else {
      Issue.record("a relative path must not be read")
      return
    }
  }
}

/// One creation at a time, never repeated, and the first message with its files.
@MainActor
@Suite("Starting a session", .timeLimit(.minutes(1)))
struct CreationFlowTests {
  private let selection = newSessionSelection

  @Test("A session with no first message is created and no message is sent")
  func createsWithoutMessage() async throws {
    let server = try creationRoutes()
    try acceptCreation(server)
    let creation = try await loadedCreation(server)
    await creation.create(selection, title: "", firstMessage: "   ")
    #expect(createdError(creation) == nil)
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").isEmpty)
    #expect(creation.canCreate)
    creation.reset()
    #expect(creation.phase == .editing)
  }

  @Test("A definite refusal returns to the form; a reset clears it")
  func refused() async throws {
    let server = try creationRoutes()
    server.fail("/v1/sessions", method: "POST", status: 400, detail: "bad")
    let creation = try await loadedCreation(server)
    await creation.create(selection, title: "", firstMessage: "hi")
    guard case .failed = creation.phase else {
      Issue.record("phase: \(creation.phase)")
      return
    }
    #expect(creation.canCreate)
    creation.reset()
    #expect(creation.phase == .editing)
  }

  @Test("An uncertain creation can't be reset away, only acknowledged")
  func uncertainStays() async throws {
    let server = try creationRoutes()
    server.dropConnection("/v1/sessions", method: "POST")
    let creation = try await loadedCreation(server)
    await creation.create(selection, title: "", firstMessage: "")
    creation.reset()
    guard case .uncertain = creation.phase else {
      Issue.record("phase: \(creation.phase)")
      return
    }
    creation.acknowledgeUncertain()
    #expect(creation.phase == .editing)
    creation.acknowledgeUncertain()
    #expect(creation.phase == .editing)
  }

  @Test("A second creation can't start while one is in flight")
  func oneAtATime() async throws {
    let server = try creationRoutes()
    try acceptCreation(server)
    let gate = server.hold("/v1/sessions", method: "POST")
    let creation = try await loadedCreation(server)
    let first = Task { await creation.create(newSessionSelection, title: "", firstMessage: "") }
    try await eventually("the post") { gate.arrivals == 1 }
    #expect(!creation.canCreate)
    await creation.create(selection, title: "", firstMessage: "")
    creation.reset()
    #expect(creation.phase == .creating, "a reset can't drop a request in flight")
    await creation.createInSandbox(
      selection, target: SandboxTarget(provider: nil, profile: nil, workspaces: []), title: "")
    gate.release()
    await first.value
    #expect(server.requests(to: "/v1/sessions", method: "POST").count == 1)
  }

  @Test("Retrying the first message sends to the same session and never creates another")
  func retriesFirstMessage() async throws {
    let server = try creationRoutes()
    try acceptCreation(server)
    let creation = try await loadedCreation(server)
    await creation.retryFirstMessage()
    #expect(creation.phase == .editing, "nothing to retry yet")

    await creation.create(selection, title: "", firstMessage: "hi")
    #expect(createdError(creation) != nil)

    server.route(
      "/v1/sessions/conv_created/events", method: "POST", .json(#"{"queued":true}"#, status: 200))
    await creation.retryFirstMessage()
    #expect(createdError(creation) == nil)
    #expect(server.requests(to: "/v1/sessions", method: "POST").count == 1)
    await creation.retryFirstMessage()
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").count <= 3)
  }

  @Test("A retry that fails again keeps the error to show")
  func retryFailsAgain() async throws {
    let server = try creationRoutes()
    try acceptCreation(server)
    let creation = try await loadedCreation(server)
    await creation.create(selection, title: "", firstMessage: "hi")
    await creation.retryFirstMessage()
    #expect(createdError(creation) != nil)
    #expect(server.requests(to: "/v1/sessions", method: "POST").count == 1)
  }

  @Test("Staged files upload with the first message and leave the form")
  func stagedFiles() async throws {
    let server = try creationRoutes()
    try acceptCreation(server)
    server.route(
      "/v1/sessions/conv_created/resources/files", method: "POST",
      .json(#"{"id":"file_1","session_id":"conv_created"}"#, status: 201))
    server.route(
      "/v1/sessions/conv_created/events", method: "POST", .json(#"{"queued":true}"#))
    let creation = try await loadedCreation(server)
    let file = PendingAttachment(filename: "a.txt", mediaType: "text/plain", data: Data("x".utf8))
    let other = PendingAttachment(filename: "b.txt", mediaType: nil, data: Data("y".utf8))
    creation.stageAttachment(file)
    creation.stageAttachment(other)
    creation.removeAttachment(other.id)
    #expect(creation.attachments.map(\.filename) == ["a.txt"])

    await creation.create(selection, title: "", firstMessage: "hi")
    #expect(createdError(creation) == nil)
    #expect(creation.attachments.isEmpty)
    #expect(server.requests(to: "/v1/sessions/conv_created/resources/files").count == 1)
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").count == 1)
  }

  private func agentServer() throws -> RouteServer {
    let server = try creationRoutes()
    try acceptCreation(server)
    server.route(
      "/v1/sessions/conv_created/events", method: "POST", .json(#"{"queued":true}"#))
    return server
  }

  private let draft = AgentDraft(
    name: "reviewer", description: "", instructions: "", harness: "codex-native", model: "m",
    mcpServers: [])

  @Test("A session with a new custom agent starts, then is sent its first message")
  func customAgent() async throws {
    let server = try agentServer()
    server.route(
      "/v1/hosts/host_a/runners", method: "POST", .json(#"{"runner_id":"run_1"}"#, status: 201))
    let creation = try await loadedCreation(server)
    await creation.create(agent: draft, selection, firstMessage: "hello")
    #expect(createdError(creation) == nil, "\(creation.phase)")
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").count == 1)
  }

  @Test("A custom agent that can't start keeps the session and the message for the retry")
  func customAgentNotStarted() async throws {
    let server = try agentServer()
    server.fail("/v1/hosts/host_a/runners", method: "POST")
    let creation = try await loadedCreation(server)
    await creation.create(agent: draft, selection, firstMessage: "hello")
    #expect(createdError(creation) != nil, "\(creation.phase)")
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").isEmpty)

    await creation.retryFirstMessage()
    #expect(createdError(creation) == nil, "\(creation.phase)")
    #expect(server.requests(to: "/v1/sessions", method: "POST").count == 1)
  }

  @Test("A sandbox session is created, then sent its first message")
  func sandbox() async throws {
    let server = try creationRoutes()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"agent_install":true,"managed_sandboxes_enabled":true,"sandbox_providers":["modal"]}"#
      ))
    try acceptCreation(server)
    server.route(
      "/v1/sessions/conv_created/events", method: "POST", .json(#"{"queued":true}"#))
    let creation = try await loadedCreation(server)
    let target = SandboxTarget(
      provider: "modal", profile: nil, workspaces: ["https://github.com/example/repo#main"])
    await creation.createInSandbox(
      selection, target: target, title: "Scratch", firstMessage: "hello")
    #expect(createdError(creation) == nil, "\(creation.phase)")
    #expect(server.requests(to: "/v1/sessions/conv_created/events", method: "POST").count == 1)
  }
}
