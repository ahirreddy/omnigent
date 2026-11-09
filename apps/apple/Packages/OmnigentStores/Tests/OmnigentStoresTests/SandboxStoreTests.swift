import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

@MainActor
@Suite("Sandbox launch options", .timeLimit(.minutes(1)))
struct SandboxStoreTests {
  private let profilesPath = "/v1/sandbox-profiles"
  private let reposPath = "/v1/connections/github/repos"
  private let branchesPath = "/v1/connections/github/repos/org/app/branches"
  private let profilesJSON =
    #"{"profiles":[{"id":"p1","name":"GPU","description":"","provider":"modal","revision":"r1"}],"managed_providers":["modal"],"next_cursor":null}"#

  private func sandboxes(_ server: RouteServer) async throws -> SandboxStore {
    let store = try await connectedStore(server)
    return try #require(store.sandboxes())
  }

  @Test("Profiles load once, and again only after a failure")
  func profilesLoadOnce() async throws {
    let server = RouteServer()
    server.fail(profilesPath)
    let sandboxes = try await sandboxes(server)
    await sandboxes.loadProfiles("modal")
    guard case .failed = sandboxes.profiles["modal"] else {
      Issue.record("profiles: \(String(describing: sandboxes.profiles["modal"]))")
      return
    }

    server.route(profilesPath, .json(profilesJSON))
    await sandboxes.loadProfiles("modal")
    #expect(sandboxes.profiles["modal"]?.value?.profiles.map(\.id) == ["p1"])
    await sandboxes.loadProfiles("modal")
    #expect(server.requests(to: profilesPath).count == 2)
  }

  @Test("A load in flight isn't started twice")
  func profilesInFlight() async throws {
    let server = RouteServer()
    server.route(profilesPath, .json(profilesJSON))
    let gate = server.hold(profilesPath)
    let sandboxes = try await sandboxes(server)
    let first = Task { await sandboxes.loadProfiles("modal") }
    try await eventually("the read to start") { gate.arrivals == 1 }
    #expect(sandboxes.profiles["modal"] == .loading)
    await sandboxes.loadProfiles("modal")
    gate.release()
    await first.value
    #expect(gate.arrivals == 1)
  }

  @Test("Searching returns matches or the reason, without touching the loaded page")
  func searching() async throws {
    let server = RouteServer()
    server.route(profilesPath, .json(profilesJSON))
    let sandboxes = try await sandboxes(server)
    let found = await sandboxes.searchProfiles("modal", text: "gp")
    #expect(try found.get().profiles.map(\.id) == ["p1"])
    #expect(sandboxes.profiles["modal"] == nil)

    server.fail(profilesPath)
    let failed = await sandboxes.searchProfiles("modal", text: "gp")
    #expect(throws: CoreError.self) { try failed.get() }
  }

  @Test("Repositories load once, and again only after a failure")
  func repositories() async throws {
    let server = RouteServer()
    server.fail(reposPath)
    let sandboxes = try await sandboxes(server)
    await sandboxes.loadGithubRepos()
    guard case .failed = sandboxes.githubRepos else {
      Issue.record("repos: \(sandboxes.githubRepos)")
      return
    }
    server.route(reposPath, .json(#"{"connected":true,"repos":[]}"#))
    await sandboxes.loadGithubRepos()
    #expect(sandboxes.githubRepos.value != nil, "\(sandboxes.githubRepos)")
    await sandboxes.loadGithubRepos()
    #expect(server.requests(to: reposPath).count == 2)
  }

  @Test("Branches load per repository, and a bad name fails only that repository")
  func branches() async throws {
    let server = RouteServer()
    server.route(branchesPath, .json(#"{"connected":true,"branches":["main","dev"]}"#))
    let sandboxes = try await sandboxes(server)
    await sandboxes.loadBranches("org/app")
    #expect(sandboxes.branches["org/app"]?.value == ["main", "dev"])
    await sandboxes.loadBranches("org/app")
    #expect(server.requests(to: branchesPath).count == 1)

    await sandboxes.loadBranches("not a repository")
    guard case .failed = sandboxes.branches["not a repository"] else {
      Issue.record("branches: \(String(describing: sandboxes.branches["not a repository"]))")
      return
    }
    #expect(sandboxes.branches["org/app"]?.value == ["main", "dev"])
  }

  @Test("Fork defaults keep what loaded and read again after a failure")
  func forkDefaults() async throws {
    let server = RouteServer()
    server.fail("/v1/sessions/conv_src")
    let sandboxes = try await sandboxes(server)
    await sandboxes.loadForkDefaults("conv_src")
    guard case .failed = sandboxes.forkDefaults["conv_src"] else {
      Issue.record("defaults: \(String(describing: sandboxes.forkDefaults["conv_src"]))")
      return
    }

    server.route(
      "/v1/sessions/conv_src",
      .json(
        #"{"id":"conv_src","status":"idle","created_at":1,"permission_level":4,"labels":{"omnigent.sandbox.repo":"https://github.com/o/a"},"sandbox_profile":{"id":"p1","name":"GPU","provider":"modal","revision":"r1"}}"#
      ))
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"session_fork_workspaces":false}"#))
    await sandboxes.loadForkDefaults("conv_src")
    #expect(sandboxes.forkDefaults["conv_src"]?.value != nil)
    let reads = server.requests(to: "/v1/sessions/conv_src").count
    await sandboxes.loadForkDefaults("conv_src")
    #expect(server.requests(to: "/v1/sessions/conv_src").count == reads)
  }
}

@MainActor
@Suite("Project settings", .timeLimit(.minutes(1)))
struct ProjectSettingsStoreTests {
  private let project = ProjectSummary(id: "p1", name: "Alpha", icon: nil)
  private let projectPath = "/v1/projects/p1"
  private let defaults = ProjectSettings(
    hostId: "host_a", workspace: "/work", useWorktree: nil, baseBranch: nil, agentId: nil,
    model: nil, effort: nil)

  private func settingsStore(_ server: RouteServer) async throws -> ProjectSettingsStore {
    let store = try await connectedStore(server)
    return try #require(store.projectSettings(project))
  }

  private func storedProject(_ server: RouteServer) {
    server.route(
      projectPath, method: "GET",
      .json(#"{"id":"p1","name":"Alpha","config":{"host_id":"host_a","keep":"me"}}"#))
    server.route(projectPath, method: "PATCH", .json(#"{"id":"p1","name":"Alpha","config":{}}"#))
    server.route(
      "/v1/hosts", .json(#"{"hosts":[{"host_id":"host_a","name":"Mac","status":"online"}]}"#))
    server.route("/v1/agents", .json(#"{"data":[],"has_more":false}"#))
  }

  @Test("Loading reads the stored defaults and the catalog independently")
  func loading() async throws {
    let server = RouteServer()
    storedProject(server)
    let settings = try await settingsStore(server)
    await settings.load()
    #expect(settings.settings.value != nil, "\(settings.settings)")
    #expect(settings.catalog.value != nil, "\(settings.catalog)")

    server.fail(projectPath, method: "GET")
    await settings.load()
    guard case .failed = settings.settings else {
      Issue.record("settings: \(settings.settings)")
      return
    }
    #expect(settings.catalog.value != nil, "a failed project read keeps the catalog")

    storedProject(server)
    server.fail("/v1/hosts")
    await settings.load()
    #expect(settings.settings.value != nil)
    guard case .failed = settings.catalog else {
      Issue.record("catalog: \(settings.catalog)")
      return
    }
  }

  @Test("Saving needs loaded settings, keeps other stored keys and reports a refusal")
  func saving() async throws {
    let server = RouteServer()
    storedProject(server)
    let settings = try await settingsStore(server)
    #expect(!(await settings.save(defaults, alwaysUseWorktree: false)))
    #expect(server.requests(to: projectPath, method: "PATCH").isEmpty)

    await settings.load()
    #expect(await settings.save(defaults, alwaysUseWorktree: false))
    #expect(settings.saveError == nil)
    #expect(settings.project.id == "p1")
    #expect(!settings.isSaving)
    let write = try #require(server.requests(to: projectPath, method: "PATCH").first)
    let config = try #require(try server.body(of: write)["config"] as? [String: Any])
    #expect(config["keep"] as? String == "me")

    server.fail(projectPath, method: "PATCH")
    #expect(!(await settings.save(defaults, alwaysUseWorktree: false)))
    #expect(settings.saveError != nil)
    #expect(!settings.isSaving)

    server.route(projectPath, method: "PATCH", .json(#"{"id":"p1","name":"Alpha","config":{}}"#))
    #expect(await settings.save(defaults, alwaysUseWorktree: false))
    #expect(settings.saveError == nil, "a later save clears the failure")
  }

  @Test("No agent or host means no models; a failed read says why")
  func models() async throws {
    let server = RouteServer()
    storedProject(server)
    let settings = try await settingsStore(server)
    await settings.loadModels(agentID: nil, hostID: "host_a")
    #expect(settings.models == .idle)
    await settings.loadModels(agentID: "ag", hostID: nil)
    #expect(settings.models == .idle)

    await settings.loadModels(agentID: "ag", hostID: "host_a")
    guard case .failed = settings.models else {
      Issue.record("models: \(settings.models)")
      return
    }
  }

  @Test("An older model read can't overwrite a newer choice")
  func modelsSupersede() async throws {
    let server = RouteServer()
    storedProject(server)
    let gate = server.hold("/v1/agents")
    let settings = try await settingsStore(server)
    let older = Task { await settings.loadModels(agentID: "ag", hostID: "host_a") }
    try await eventually("the older read to start") { gate.arrivals > 0 }
    #expect(settings.models == .loading)
    await settings.loadModels(agentID: nil, hostID: nil)
    gate.release()
    await older.value
    #expect(settings.models == .idle, "\(settings.models)")
  }
}
