import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

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
