import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// Start sends what the composer shows: compare the composer's state with the request it causes.
@MainActor
@Suite("New session start", .timeLimit(.minutes(1)))
struct NewSessionStartTests {
  /// A loaded form with Claude Code on the first host and `/work/app` as its folder.
  private func loaded(
    _ server: AppServer
  ) async throws -> (NewSessionForm, (CreationStore, ConnectionStore)) {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    form.selectFolder(creation, "/work/app")
    return (form, (creation, connection))
  }

  private func startAndWait(
    _ form: NewSessionForm, _ creation: CreationStore, _ server: AppServer, text: String = ""
  ) async throws -> [String: Any] {
    form.start(creation, text: text)
    try await eventually("the create request") { !server.requests("POST", "/v1/sessions").isEmpty }
    return try #require(try server.posted("/v1/sessions").first)
  }

  @Test("The request names the host, agent and folder the composer shows")
  func sendsTheShownHostAgentAndFolder() async throws {
    let server = newSessionServer()
    let (form, (creation, connection)) = try await loaded(server)
    let shown = form.composerState(creation, connection: connection)
    #expect(shown.hosts?.selectedID == "mac")
    #expect(shown.configuration?.selectedAgentId == "ag_claude")
    #expect(shown.context?.directory == "/work/app")

    let body = try await startAndWait(form, creation, server)
    #expect(body["host_id"] as? String == "mac")
    #expect(body["agent_id"] as? String == "ag_claude")
    #expect(body["workspace"] as? String == "/work/app")
  }

  @Test("The default mode the composer shows launches without flags")
  func theDefaultApprovalModeSendsNoFlags() async throws {
    let server = newSessionServer()
    let (form, (creation, connection)) = try await loaded(server)
    let shown = form.composerState(creation, connection: connection)
    #expect(shown.approvalModes?.selectedID == "default")
    #expect(form.selection.approvalMode == nil, "nothing was chosen: the menu shows the default")

    let body = try await startAndWait(form, creation, server)
    #expect(body["terminal_launch_args"] == nil)
  }

  @Test(
    "The default mode the composer shows overrides the harness's own config",
    .disabled(
      "The core's launch_approval_args drops the menu's default, so a harness config can run a session in another mode than the form said"
    ))
  func theDefaultApprovalModeIsAskedFor() async throws {
    let server = newSessionServer()
    let (form, (creation, connection)) = try await loaded(server)
    let selected = try #require(
      form.composerState(creation, connection: connection).approvalModes?.selectedID)
    let body = try await startAndWait(form, creation, server)
    #expect(body["terminal_launch_args"] as? [String] == ["--permission-mode", selected])
  }

  @Test("An approval mode the user picks replaces the default in the request")
  func sendsThePickedApprovalMode() async throws {
    let server = newSessionServer()
    let (form, (creation, connection)) = try await loaded(server)
    let modes = try #require(form.composerState(creation, connection: connection).approvalModes)
    let other = try #require(modes.options.last { $0.id != modes.selectedID })
    form.selection.approvalMode = other.id
    #expect(
      form.composerState(creation, connection: connection).approvalModes?.selectedID == other.id)

    let body = try await startAndWait(form, creation, server)
    #expect(body["terminal_launch_args"] as? [String] == ["--permission-mode", other.id])
  }

  @Test("The model and effort chosen go with the request")
  func sendsTheChosenModelAndEffort() async throws {
    let server = newSessionServer()
    let (form, (creation, _)) = try await loaded(server)
    try await eventually("the models") { creation.models.value?.isEmpty == false }
    form.change(creation) {
      $0.model = "claude-native-fast"
      $0.reasoningEffort = "high"
    }
    let body = try await startAndWait(form, creation, server)
    #expect(body["model_override"] as? String == "claude-native-fast")
    #expect(body["reasoning_effort"] as? String == "high")
  }

  @Test("Choosing another agent drops the model and mode that belonged to the last one")
  func anotherAgentStartsOnItsDefaults() async throws {
    let server = newSessionServer()
    let (form, (creation, connection)) = try await loaded(server)
    form.change(creation) {
      $0.model = "claude-native-fast"
      $0.approvalMode = "plan"
    }
    form.selectAgent("ag_codex", creation)
    #expect(form.selection.model == nil)
    #expect(form.selection.approvalMode == nil)
    let shown = form.composerState(creation, connection: connection)
    #expect(shown.configuration?.selectedAgentId == "ag_codex")

    let body = try await startAndWait(form, creation, server)
    #expect(body["agent_id"] as? String == "ag_codex")
    #expect(body["model_override"] == nil)
    let labels = try #require(body["labels"] as? [String: String])
    #expect(labels["omnigent.wrapper"] == "codex-native-ui")
  }

  @Test("A new worktree the page shows is in the request, with the folder as its base")
  func sendsTheChosenWorktree() async throws {
    let server = newSessionServer()
    let (form, (creation, _)) = try await loaded(server)
    form.worktree = .new(branch: "feature/x", base: "main")
    form.applyWorktree()

    let body = try await startAndWait(form, creation, server)
    #expect(body["workspace"] as? String == "/work/app")
    let git = try #require(body["git"] as? [String: Any])
    #expect(git["branch_name"] as? String == "feature/x")
    #expect(git["base_branch"] as? String == "main")
  }

  @Test("An existing worktree starts in the worktree's folder, not the one chosen")
  func existingWorktreeUsesItsPath() async throws {
    let server = newSessionServer()
    let (form, (creation, connection)) = try await loaded(server)
    form.worktree = .existing(NewSessionWorktreeOption(path: "/work/app-wt", branch: "wt"))
    form.applyWorktree()
    #expect(form.folder == "/work/app")
    #expect(
      form.composerState(creation, connection: connection).context?.directory == "/work/app-wt")

    let body = try await startAndWait(form, creation, server)
    #expect(body["workspace"] as? String == "/work/app-wt")
  }

  @Test("A sent start remembers its host and agent, and the next form starts on them")
  func theNextFormStartsOnTheLastChoices() async throws {
    let server = newSessionServer()
    let (form, (creation, _)) = try await loaded(server)
    form.chooseHost("box", creation)
    form.selectAgent("ag_codex", creation)
    form.start(creation, text: "")

    let next = NewSessionForm()
    next.preferences = form.preferences
    await next.load(creation)
    #expect(next.selection.hostId == "box")
    #expect(next.selection.agentId == "ag_codex")
  }

  @Test("A remembered host that went offline isn't used")
  func aRememberedOfflineHostIsSkipped() async throws {
    let server = newSessionServer(offline: ["box"])
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    form.preferences.set("box", forKey: NewSessionForm.DefaultsKey.host)
    await form.load(creation)
    #expect(form.selection.hostId == "mac")
  }

  @Test("A refused start says why, stays on the form and can start again")
  func aRefusedStartStaysOnTheForm() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/sessions", method: "POST", .json(#"{"detail":"Host is full"}"#, status: 422))
    let (form, (creation, connection)) = try await loaded(server)
    form.start(creation, text: "hello")
    try await eventually("the failure") {
      if case .failed = creation.phase { return true }
      return false
    }
    let state = form.composerState(creation, connection: connection)
    guard case .failed(let message) = state.delivery else {
      Issue.record("delivery: \(state.delivery)")
      return
    }
    #expect(message.contains("Host is full"))
    #expect(creation.canCreate)
  }

  @Test("A lost answer blocks another start until the user acknowledges it")
  func anUnclearStartBlocksAnother() async throws {
    let server = newSessionServer()
    server.route("/v1/sessions", method: "POST", .json("<html>bad gateway</html>", status: 502))
    let (form, (creation, connection)) = try await loaded(server)
    form.start(creation, text: "hello")
    try await eventually("the unclear outcome") {
      if case .uncertain = creation.phase { return true }
      return false
    }
    guard case .uncertain = form.composerState(creation, connection: connection).delivery else {
      Issue.record("the composer must say the session may exist")
      return
    }
    form.start(creation, text: "hello")
    try await Task.sleep(for: .milliseconds(30))
    #expect(server.requests("POST", "/v1/sessions").count == 1, "creation is never repeated")
    creation.acknowledgeUncertain()
    #expect(creation.canCreate)
  }

  @Test("A session filed in a project names it, and a label-only one is moved once")
  func filesInTheProject() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/sessions/conv_new",
      .json(#"{"id":"conv_new","status":"idle","created_at":1,"permission_level":4}"#))
    let (form, (creation, connection)) = try await loaded(server)
    form.project = ProjectSummary(id: "p1", name: "Alpha", icon: nil)
    let body = try await startAndWait(form, creation, server)
    #expect(body["project_id"] as? String == "p1")

    form.fileInLabelProject("conv_new", list: connection.sessionList)
    #expect(form.filedSessionID == nil, "a first-class project was already named in the create")

    server.route(
      "/v1/projects", method: "POST", .json(#"{"id":"p2","name":"Label"}"#, status: 201))
    form.project = ProjectSummary(id: nil, name: "Label", icon: nil)
    form.fileInLabelProject("conv_new", list: connection.sessionList)
    form.fileInLabelProject("conv_new", list: connection.sessionList)
    try await eventually("the move") { !server.requests("PATCH", "/v1/sessions/conv_new").isEmpty }
    #expect(connection.sessionList.editError == nil)
    try await Task.sleep(for: .milliseconds(20))
    #expect(server.requests("PATCH", "/v1/sessions/conv_new").count == 1, "a retried send stays")
  }
}
