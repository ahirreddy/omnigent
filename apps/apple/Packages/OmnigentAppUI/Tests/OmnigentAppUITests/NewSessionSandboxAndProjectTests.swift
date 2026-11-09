import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The Host menu's rows (a machine or a new sandbox) and a project's stored defaults.
@MainActor
@Suite("New session hosts, sandboxes and projects", .timeLimit(.minutes(1)))
struct NewSessionSandboxAndProjectTests {
  private func sandboxServer() -> AppServer {
    let server = newSessionServer()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,"sandbox_providers":["modal"],"default_sandbox_provider":"modal"}"#
      ))
    return server
  }

  private func opened(
    _ server: AppServer
  ) async throws -> (NewSessionForm, (CreationStore, ConnectionStore)) {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    return (form, (creation, connection))
  }

  @Test("Picking a sandbox row sends a managed create, without what only applied to the host")
  func aSandboxStartSendsWhatItShows() async throws {
    let server = sandboxServer()
    let (form, (creation, connection)) = try await opened(server)
    form.selectFolder(creation, "/work")
    form.change(creation) {
      $0.model = "claude-native-fast"
      $0.reasoningEffort = "high"
    }

    form.chooseHostRow(NewSessionAdapter.sandboxHostID("modal"), creation)
    #expect(form.isSandbox)
    let state = form.composerState(creation, connection: connection)
    #expect(state.hosts?.selectedID == NewSessionAdapter.sandboxHostID("modal"))
    #expect(state.configuration?.modelOptions.isEmpty == true, "no model is offered")
    #expect(state.context?.directory == nil)
    #expect(state.availability == .available)

    form.start(creation, text: "")
    try await eventually("the create") { !server.requests("POST", "/v1/sessions").isEmpty }
    let body = try #require(try server.posted("/v1/sessions").first)
    #expect(body["host_type"] as? String == "managed")
    #expect(body["sandbox_provider"] as? String == "modal")
    #expect(body["agent_id"] as? String == "ag_claude")
    #expect(body["workspace"] == nil)
    #expect(body["model_override"] == nil, "the composer shows no model on a sandbox")
    #expect(body["reasoning_effort"] == nil)
  }

  @Test("Another provider forgets the profile chosen for the last")
  func anotherProviderDropsTheProfile() async throws {
    let (form, (creation, _)) = try await opened(sandboxServer())
    let provider = NewSessionAdapter.sandboxHostID("modal")
    form.chooseHostRow(provider, creation)
    form.sandbox.profile = SandboxProfileOption(id: "prof", name: "Prof", revision: "1")
    form.chooseHostRow(provider, creation)
    #expect(form.sandbox.profile != nil)
    form.chooseHostRow(NewSessionAdapter.sandboxHostID("other"), creation)
    #expect(form.sandbox.profile == nil)
    #expect(form.sandbox.provider == "other")
    form.rememberChoices()
    #expect(form.preferences.string(forKey: NewSessionForm.DefaultsKey.sandboxProvider) == "other")
  }

  @Test("Picking the machine already selected keeps the folder and the worktree")
  func theSameMachineKeepsTheWorktree() async throws {
    let (form, (creation, _)) = try await opened(sandboxServer())
    form.selectFolder(creation, "/work")
    form.worktree = .new(branch: "feature", base: "")
    form.applyWorktree()

    form.chooseHostRow("mac", creation)
    #expect(form.folder == "/work")
    #expect(form.worktree == .new(branch: "feature", base: ""))
    #expect(form.selection.git?.branchName == "feature")

    form.chooseHostRow(NewSessionAdapter.sandboxHostID("modal"), creation)
    form.chooseHostRow("mac", creation)
    #expect(!form.isSandbox)
    #expect(form.selection.workspace == "/work", "back from a sandbox to the same machine")
    #expect(form.selection.git?.branchName == "feature")
  }

  @Test("Another machine drops the folder and worktree, and its worktrees are read again")
  func anotherMachineStartsClean() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/hosts/mac/worktrees",
      .json(#"{"data":[{"path":"/work","branch":"main","is_main":true}]}"#))
    let (form, (creation, _)) = try await opened(server)
    form.selectFolder(creation, "/work")
    try await eventually("the worktrees") { creation.worktrees.value != nil }
    form.worktree = .new(branch: "feature", base: "")
    form.applyWorktree()

    form.chooseHostRow("box", creation)
    #expect(form.folder.isEmpty)
    #expect(form.worktree == .none)
    #expect(form.selection.git == nil)
    #expect(form.selection.hostId == "box")
    try await eventually("the old worktrees to clear") { creation.worktrees == .idle }
    #expect(!form.options(creation).offersWorktrees)
  }

  @Test("A host going away while the user chose nothing moves on without its folder")
  func anAutomaticHostChangeDropsTheFolder() async throws {
    let server = newSessionServer()
    let (form, (creation, _)) = try await opened(server)
    form.selectFolder(creation, "/mac-only")
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"mac","status":"offline"},{"host_id":"box","name":"box","status":"online"}]}"#
      ))
    await form.reloadCatalog(creation)
    #expect(form.selection.hostId == "box")
    #expect(form.folder.isEmpty, "that path belongs to the host that left")
  }

  @Test("A project fills host, agent, model, effort, folder and worktree from its settings")
  func aProjectAppliesItsDefaults() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1",
      .json(
        #"{"id":"p1","name":"Alpha","config":{"host_id":"box","agent_id":"ag_codex","model":"codex-native-fast","effort":"high","workspace":"/alpha","use_worktree":true,"base_branch":"develop"}}"#
      ))
    let (form, (creation, _)) = try await opened(server)
    await form.applyProject(ProjectSummary(id: "p1", name: "Alpha", icon: nil), creation)
    #expect(form.selection.hostId == "box")
    #expect(form.selection.agentId == "ag_codex")
    #expect(form.selection.model == "codex-native-fast")
    #expect(form.selection.reasoningEffort == "high")
    #expect(form.folder == "/alpha")
    #expect(form.selection.git?.baseBranch == "develop")
    #expect(form.selection.git?.branchName.hasPrefix("worktree-") == true)
    #expect(form.projectError == nil)
  }

  @Test("A project that names another host and no folder doesn't keep the last host's path")
  func aProjectHostChangeDropsTheFolder() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1", .json(#"{"id":"p1","name":"Alpha","config":{"host_id":"box"}}"#))
    let (form, (creation, _)) = try await opened(server)
    form.selectFolder(creation, "/mac-only")
    await form.applyProject(ProjectSummary(id: "p1", name: "Alpha", icon: nil), creation)
    #expect(form.selection.hostId == "box")
    #expect(form.folder.isEmpty)
  }

  @Test("A project's sandbox choice, an unknown agent and a relative folder")
  func aProjectOnASandbox() async throws {
    let server = sandboxServer()
    let choice = projectSandboxHostChoice()
    server.route(
      "/v1/projects/p1",
      .json(
        #"{"id":"p1","name":"Alpha","config":{"host_id":"\#(choice)","agent_id":"gone","workspace":"relative"}}"#
      ))
    let (form, (creation, _)) = try await opened(server)
    let agent = form.selection.agentId
    await form.applyProject(ProjectSummary(id: "p1", name: "Alpha", icon: nil), creation)
    #expect(form.isSandbox)
    #expect(form.selection.agentId == agent, "an agent no longer offered isn't chosen")
    #expect(form.folder.isEmpty)
  }

  @Test("Project defaults that can't be read are reported, and the project stays chosen")
  func aProjectThatCannotBeRead() async throws {
    let server = newSessionServer()
    server.route("/v1/projects/p1", .json(#"{"detail":"nope"}"#, status: 500))
    let (form, (creation, connection)) = try await opened(server)
    await form.applyProject(ProjectSummary(id: "p1", name: "Alpha", icon: nil), creation)
    #expect(form.project?.name == "Alpha")
    #expect(form.projectError?.hasPrefix("Could not read Alpha's defaults") == true)
    guard case .failed = form.composerState(creation, connection: connection).delivery else {
      Issue.record("the failure must show")
      return
    }
  }

  @Test("A project chosen while another's defaults load doesn't get them")
  func aLateProjectAnswerIsDropped() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1", .json(#"{"id":"p1","name":"One","config":{"workspace":"/one"}}"#))
    let (form, (creation, _)) = try await opened(server)
    let task = Task {
      await form.applyProject(ProjectSummary(id: "p1", name: "One", icon: nil), creation)
    }
    form.project = ProjectSummary(id: nil, name: "Other", icon: nil)
    await task.value
    #expect(form.folder.isEmpty || form.project?.name == "One")
  }

  @Test("A new or imported agent is selected once the catalog has it")
  func anInstalledAgentIsSelected() async throws {
    let (form, (creation, _)) = try await opened(newSessionServer())
    let agent = ManagedAgent(
      id: "ag_codex", name: "Codex", description: nil, harness: "codex-native",
      harnessLabel: "Codex", createdAt: nil, updatedAt: nil, builtin: false)
    await form.agentInstalled(agent, creation)
    #expect(form.selection.agentId == "ag_codex")
    #expect(form.agentWasChosen)
  }
}
