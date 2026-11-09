import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing
import UniformTypeIdentifiers

@testable import OmnigentAppUI

/// What the new-session composer and the chips under it say in each state of the form.
@MainActor
@Suite("New session composer state", .timeLimit(.minutes(1)))
struct NewSessionComposerStateTests {
  private func opened(
    _ server: AppServer = newSessionServer()
  ) async throws -> (NewSessionForm, (CreationStore, ConnectionStore)) {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    await form.load(creation)
    return (form, (creation, connection))
  }

  @Test("Start stays off and says why until the catalog is in and a folder is chosen")
  func availabilityFollowsTheForm() async throws {
    let connection = try await signedInStore(newSessionServer())
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    #expect(
      form.composerState(creation, connection: connection).availability.reason?.contains("Loading")
        == true)
    await form.load(creation)
    #expect(
      form.composerState(creation, connection: connection).availability.reason
        == "Choose the folder the session works in.")
    form.selectFolder(creation, "/work")
    try await eventually("the models") { creation.models.value != nil }
    #expect(form.composerState(creation, connection: connection).availability == .available)
  }

  @Test("A catalog that can't load says why")
  func aCatalogFailureIsShown() async throws {
    let server = newSessionServer()
    server.route("/v1/agents", .json(#"{"detail":"agents are down"}"#, status: 500))
    let (form, (creation, connection)) = try await opened(server)
    let reason = form.composerState(creation, connection: connection).availability.reason
    #expect(reason?.isEmpty == false)
    #expect(reason?.contains("Choose") == false)
    #expect(form.needsHost(creation) == false, "a failed read isn't evidence of no hosts")
  }

  @Test("With no host online the page says so, offers to connect one and picks one when it comes")
  func noHostOnline() async throws {
    let server = newSessionServer(offline: ["mac", "box"])
    let (form, (creation, connection)) = try await opened(server)
    #expect(form.needsHost(creation))
    #expect(form.options(creation).needsHost)
    #expect(
      form.composerState(creation, connection: connection).availability.reason
        == "Connect a host to run agents on.")

    form.hostCheckInterval = .milliseconds(1)
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"box","name":"box","status":"online","configured_harnesses":{"claude-native":true}}]}"#
      ))
    await form.waitForHost(creation)
    #expect(!form.needsHost(creation))
    #expect(form.selection.hostId == "box")
  }

  @Test("Waiting for a host ends when the screen leaves")
  func waitingIsCancelled() async throws {
    let (form, (creation, _)) = try await opened(newSessionServer(offline: ["mac", "box"]))
    form.hostCheckInterval = .seconds(60)
    let wait = Task { await form.waitForHost(creation) }
    try await Task.sleep(for: .milliseconds(5))
    wait.cancel()
    await wait.value
    #expect(form.needsHost(creation), "nothing connected, and the wait still ended")
  }

  @Test("A harness that isn't ready gets the amber notice with Set Up, online hosts only")
  func harnessNotice() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/hosts",
      .json(
        #"{"hosts":[{"host_id":"mac","name":"Mac","status":"online","configured_harnesses":{"claude-native":false,"codex-native":true}},{"host_id":"off","name":"Off","status":"offline","configured_harnesses":{"claude-native":false}}]}"#
      ))
    let (form, (creation, _)) = try await opened(server)
    #expect(form.selection.agentId == "ag_codex", "an agent ready on the host is picked by itself")
    #expect(form.harnessNotice(creation) == nil)

    form.selectAgent("ag_claude", creation)
    let notice = try #require(form.harnessNotice(creation))
    #expect(notice.text == "Claude isn't ready on Mac.")
    #expect(notice.name == "Claude")
    #expect(form.setupHarness(creation) == "claude-native")
    #expect(form.options(creation).harnessNotice == notice.text)
    #expect(form.options(creation).setUpName == "Claude")

    form.chooseHost("off", creation)
    #expect(form.harnessNotice(creation) == nil, "offline says so in the context row instead")
    form.chooseHost("mac", creation)
    form.isSandbox = true
    #expect(form.harnessNotice(creation) == nil)
  }

  @Test("Plan mode is Claude Code's approval mode")
  func planIsAnApprovalMode() async throws {
    let (form, (creation, _)) = try await opened()
    let toggle = try #require(form.planToggle(creation))
    toggle()
    #expect(form.isPlanOn)
    #expect(form.selection.approvalMode == "plan")
    #expect(form.options(creation).isPlanMode)
    toggle()
    #expect(!form.isPlanOn)
    #expect(form.selection.approvalMode == nil)
    form.isSandbox = true
    #expect(form.planToggle(creation) == nil, "a new sandbox has no plan toggle")
  }

  @Test("Codex without the server's support offers no plan toggle")
  func codexNeedsTheServer() async throws {
    let (form, (creation, _)) = try await opened()
    form.selectAgent("ag_codex", creation)
    let catalog = try #require(creation.catalog.value)
    #expect(!creationStartsInPlanMode(catalog: catalog, agentId: "ag_codex"))
    #expect(form.planToggle(creation) == nil)
  }

  @Test("Attachments stage with their kind, and an unreadable file says so")
  func attachments() async throws {
    let (form, (creation, connection)) = try await opened()
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        Issue.record("could not remove the test folder: \(error)")
      }
    }
    let file = folder.appending(path: "notes.txt")
    try Data("hello".utf8).write(to: file)
    form.stage(
      [
        .file(url: file),
        .data(Data([1, 2]), suggestedName: "photo.png", contentType: .png),
      ], in: creation)
    let chips = form.attachmentChips(creation)
    #expect(chips.map(\.title) == ["notes.txt", "photo.png"])
    #expect(chips.map(\.kind) == [.file, .image])
    #expect(chips.map(\.byteCount) == [5, 2])
    #expect(form.attachmentError == nil)

    form.stage([.file(url: folder.appending(path: "missing.txt"))], in: creation)
    #expect(form.attachmentError?.hasPrefix("Could not read missing.txt") == true)
    #expect(form.attachmentChips(creation).count == 2)
    guard case .failed(let message) = form.composerState(creation, connection: connection).delivery
    else {
      Issue.record("the failure must show in the composer")
      return
    }
    #expect(message == form.attachmentError)
  }

  @Test("The chips show the folder, its recents, its worktrees and the project")
  func options() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/hosts/mac/worktrees",
      .json(
        #"{"data":[{"path":"/work","branch":"main","is_main":true},{"path":"/wt","branch":"x","is_main":false}]}"#
      ))
    let (form, (creation, _)) = try await opened(server)
    var options = form.options(creation)
    #expect(options.folder == nil)
    #expect(options.recentFolders == ["/home/mac/src"])
    #expect(!options.offersWorktrees)

    form.selectFolder(creation, "/work")
    try await eventually("the worktrees") { creation.worktrees.value != nil }
    let project = ProjectSummary(id: "p1", name: "Alpha", icon: nil)
    form.project = project
    options = form.options(creation, projects: [project])
    #expect(options.folder == "/work")
    #expect(options.offersWorktrees)
    #expect(options.worktrees.map(\.path) == ["/wt"], "the main checkout isn't a worktree choice")
    #expect(options.project == "Alpha")
    #expect(options.projects == ["Alpha"])
  }

  @Test("Host rows show who is offline and the selection")
  func hostsInTheComposer() async throws {
    let (form, (creation, connection)) = try await opened(newSessionServer(offline: ["box"]))
    let hosts = try #require(form.composerState(creation, connection: connection).hosts)
    #expect(hosts.selectedID == "mac")
    #expect(hosts.hosts.map(\.id) == ["mac", "box"])
    #expect(hosts.hosts.map(\.isOnline) == [true, false])
  }

  @Test("A project's name becomes the placeholder")
  func placeholderNamesTheProject() async throws {
    let (form, (creation, connection)) = try await opened()
    #expect(
      form.composerState(creation, connection: connection).placeholder.hasPrefix("Describe a task"))
    form.project = ProjectSummary(id: nil, name: "Alpha", icon: nil)
    #expect(
      form.composerState(creation, connection: connection).placeholder
        == "Start a new session in Alpha")
  }

  @Test("Skills wait for a host, an online host, a folder and an agent, in that order")
  func skillsRequest() async throws {
    let (form, (creation, _)) = try await opened(newSessionServer(offline: ["box"]))
    #expect(
      form.skillsRequest(creation).unavailable == "Choose a working directory to discover skills.")
    form.selectFolder(creation, "/work")
    let ready = form.skillsRequest(creation)
    #expect(ready.unavailable == nil)
    #expect(ready.target?.folder == "/work")
    #expect(ready.target?.harness == "claude-native")
    #expect(form.mentionTarget(creation)?.folder == "/work", "native agents browse folders")

    form.chooseHost("box", creation)
    #expect(
      form.skillsRequest(creation).unavailable == "Skills unavailable while the host is offline.")
    #expect(form.mentionTarget(creation) == nil)
    form.selection.hostId = "gone"
    #expect(form.skillsRequest(creation).unavailable == "Choose a host to discover skills.")
    form.isSandbox = true
    #expect(form.skillsRequest(creation).unavailable?.contains("sandbox") == true)
  }

  @Test("An unsaved custom agent shows in the picker, needs a host and a folder, and has no model")
  func pendingAgent() async throws {
    let (form, (creation, connection)) = try await opened()
    let draft = AgentDraft(
      name: "Mine", description: "Helps", instructions: "Be kind", harness: "claude-native",
      model: "", mcpServers: [])
    form.adoptPendingAgent(draft)
    #expect(form.startsPendingAgent)
    #expect(form.selection.agentId == NewSessionForm.pendingAgentID)

    var state = form.composerState(creation, connection: connection)
    #expect(state.configuration?.selectedAgentId == NewSessionForm.pendingAgentID)
    #expect(state.configuration?.harnessChoices.last?.name == "Mine")
    #expect(state.configuration?.agentGroups[NewSessionForm.pendingAgentID] == .custom)
    #expect(state.configuration?.modelOptions.isEmpty == true)
    #expect(state.availability.reason == "Choose the folder the session works in.")
    #expect(form.skillsRequest(creation).unavailable?.contains("after this session starts") == true)
    #expect(form.selectedAgent(creation)?.description == "Helps")

    form.chooseHost("gone", creation)
    state = form.composerState(creation, connection: connection)
    #expect(state.availability.reason == "Connect this host before starting a session.")
    form.chooseHost("mac", creation)
    form.selectFolder(creation, "/work")
    #expect(form.composerState(creation, connection: connection).availability == .available)

    form.isSandbox = true
    state = form.composerState(creation, connection: connection)
    #expect(state.availability.reason == "Choose an agent.", "a sandbox can't upload one")
    #expect(form.pendingChoice == nil)
  }

  @Test("A saved next start doesn't remember the unsaved agent")
  func pendingAgentIsNotRemembered() async throws {
    let (form, _) = try await opened()
    form.selection.agentId = NewSessionForm.pendingAgentID
    form.rememberChoices()
    #expect(form.preferences.string(forKey: NewSessionForm.DefaultsKey.agent) == nil)
  }
}
