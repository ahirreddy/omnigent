import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The Add nested agent form under each destination policy: the hosts it offers, what it
/// preselects, what snaps back, and what Start sends.
@MainActor
@Suite("Add nested agent form", .serialized, .timeLimit(.minutes(1)))
struct NestedAgentFormTests {
  private let sandboxRow = NewSessionAdapter.sandboxHostID("modal")

  @Test("Each policy offers its hosts: any host, the source's only, or it and a new sandbox")
  func hostsPerPolicy() async throws {
    let any = try await loadedNestedForm(nestedServer(sandboxes: true))
    #expect(any.hostIDs == [sandboxRow, "mac", "box"])
    let current = try await loadedNestedForm(nestedServer(policy: "current_host", sandboxes: true))
    #expect(current.hostIDs == ["mac"])
    let sandboxed = try await loadedNestedForm(
      nestedServer(policy: "current_host_or_new_sandbox", sandboxes: true))
    #expect(sandboxed.hostIDs == [sandboxRow, "mac"])
    let noSandboxes = try await loadedNestedForm(
      nestedServer(policy: "current_host_or_new_sandbox"))
    #expect(noSandboxes.hostIDs == ["mac"])
  }

  @Test("The source's host and folder are chosen; the page names the source")
  func preselectsTheSource() async throws {
    let loaded = try await loadedNestedForm(nestedServer())
    let form = loaded.form
    let creation = loaded.creation
    let connection = loaded.connection
    #expect(form.selection.hostId == "mac")
    #expect(form.folder == "/work/app")
    #expect(form.heading == "Add nested agent")
    #expect(form.nested?.subtitle == "A new conversation alongside Coordinator")
    let state = form.composerState(creation, connection: connection)
    #expect(state.placeholder == "What should this agent work on?")
    let options = form.options(creation, projects: [ProjectSummary(id: "p", name: "P", icon: nil)])
    #expect(options.projects.isEmpty && options.project == nil, "no project to choose")
    // Back on the source's host, its folder fills in again; elsewhere none does.
    form.folder = ""
    #expect(form.seedNestedFolder(creation, hostID: "box"))
    #expect(form.folder.isEmpty)
    #expect(form.seedNestedFolder(creation, hostID: "mac"))
    #expect(form.folder == "/work/app")
  }

  @Test("The source's own sandbox host is offered and creates; another sandbox is not")
  func reusesTheSourceSandbox() async throws {
    let server = nestedServer(sandboxHost: "sbx")
    let other =
      #"{"id":"conv_src","status":"idle","created_at":1,"updated_at":5,"title":"","host_id":"sbx","workspace":"/sandbox/repo","permission_level":4}"#
    server.route("/v1/sessions/conv_src", .json(other))
    let loaded = try await loadedNestedForm(server)
    let form = loaded.form
    let creation = loaded.creation
    let connection = loaded.connection
    #expect(loaded.hostIDs == ["mac", "box", "sbx"])
    #expect(form.selection.hostId == "sbx")
    #expect(form.nested?.subtitle == "A new conversation alongside Untitled")
    #expect(creation.nestedUnavailableReason(form.selection, sourceHostID: "sbx") == nil)
    let rows = form.composerState(creation, connection: connection).hosts?.hosts ?? []
    #expect(rows.first { $0.id == "sbx" }?.isOnline == true)
    #expect(form.composerState(creation, connection: connection).context?.unavailableReason == nil)
  }

  @Test("A host the policy stops offering snaps back to the source's host and folder")
  func snapsBack() async throws {
    let server = nestedServer()
    let loaded = try await loadedNestedForm(server)
    let form = loaded.form
    let creation = loaded.creation
    form.chooseHostRow("box", creation)
    #expect(form.selection.hostId == "box")
    #expect(form.folder.isEmpty, "a folder is a path on one machine")
    form.enforceNestedPolicy(creation)
    #expect(form.selection.hostId == "box", "still offered")
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"sibling_sessions":true,"sibling_session_destinations":"current_host"}"#
      ))
    await creation.refreshCatalog()
    form.enforceNestedPolicy(creation)
    #expect(form.selection.hostId == "mac")
    #expect(form.folder == "/work/app")
  }

  @Test("A new sandbox the policy stops offering snaps back too")
  func sandboxSnapsBack() async throws {
    let server = nestedServer(policy: "current_host_or_new_sandbox", sandboxes: true)
    let loaded = try await loadedNestedForm(server)
    let form = loaded.form
    let creation = loaded.creation
    form.chooseHostRow(sandboxRow, creation)
    #expect(form.isSandbox)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"sibling_sessions":true,"sibling_session_destinations":"current_host","managed_sandboxes_enabled":true,"sandbox_provider":"modal"}"#
      ))
    await creation.refreshCatalog()
    form.enforceNestedPolicy(creation)
    #expect(!form.isSandbox)
    #expect(form.selection.hostId == "mac")
  }

  @Test("No worktree is made for a nested agent, even when Settings asks for one")
  func noAutomaticWorktree() async throws {
    let server = nestedServer()
    server.route(
      "/v1/hosts/mac/worktrees",
      .json(#"{"data":[{"path":"/work/app","branch":"topic","is_main":true}],"has_more":false}"#))
    server.route(
      "/v1/sessions/conv_src",
      .json(String(nestedSourceRow.dropLast()) + #","git_branch":"topic"}"#))
    let loaded = try await loadedNestedForm(server)
    let form = loaded.form
    let creation = loaded.creation
    form.preferences.set(true, forKey: GitPreferences.alwaysUseWorktreeKey)
    try await eventually("the worktrees") { creation.worktrees.value?.isEmpty == false }
    form.seedWorktree(creation)
    #expect(form.worktree == NewSessionWorktreeChoice.none)
    #expect(form.selection.git == nil)
    #expect(
      form.options(creation).defaultBaseBranch == "topic",
      "a worktree chosen by hand branches from the source's checkout")
  }

  @Test("A new sandbox goes out managed beside the source")
  func startsInANewSandbox() async throws {
    let server = nestedServer(policy: "current_host_or_new_sandbox", sandboxes: true)
    let loaded = try await loadedNestedForm(server)
    let form = loaded.form
    let creation = loaded.creation
    form.chooseHostRow(sandboxRow, creation)
    form.start(creation, text: "")
    try await eventually("the create") { !server.requests("POST", "/v1/sessions").isEmpty }
    let body = try #require(try server.posted("/v1/sessions").first)
    #expect(body["host_type"] as? String == "managed")
    #expect(body["sibling_source_id"] as? String == "conv_src")
    #expect(body["project_id"] == nil)
  }

  @Test("A refused create sends the next one under a new token")
  func refusalRenewsTheToken() async throws {
    let form = try await loadedNestedForm(nestedServer()).form
    let first = try #require(form.nested?.token)
    form.nestedCreateFailed()
    #expect(form.nested?.token != first)
  }

  @Test("A missing source and a server without nested agents say so")
  func unavailablePhases() async throws {
    let missing = try await loadedNestedForm(nestedServer(), sourceID: "conv_gone")
    #expect(missing.form.nested?.phase == .sourceUnavailable)
    #expect(missing.form.nested?.notice == "Source session is unavailable.")
    let off = try await loadedNestedForm(nestedServer(siblings: false))
    #expect(off.form.nested?.phase == .unavailable)
    #expect(off.form.nested?.notice == "Nested agents are not available on this server.")
    #expect(NestedComposer(sourceID: "x").notice == "Loading source session\u{2026}")
    #expect(off.form.nestedChoices(off.creation) == nil)
    off.form.snapToSource(off.creation)
    off.form.enforceNestedPolicy(off.creation)
    #expect(
      off.form.seedNestedFolder(off.creation, hostID: "mac"), "nothing else fills a nested folder")
    #expect(off.form.folder.isEmpty)
    #expect(!(try isolatedForm()).seedNestedFolder(off.creation, hostID: "mac"))
  }
}
