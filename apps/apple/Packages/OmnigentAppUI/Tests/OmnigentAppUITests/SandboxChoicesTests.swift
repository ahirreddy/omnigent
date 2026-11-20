import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct SandboxChoicesTests {
  private func catalog(profiles: Bool = false) -> OmnigentCoreFFI.CreationCatalog {
    OmnigentCoreFFI.CreationCatalog(
      hosts: [], agents: [], managedSandboxes: true,
      sandboxProviders: ["modal", "agent_sandbox"], defaultSandboxProvider: "modal",
      multiRepoProviders: ["agent_sandbox"], sandboxProfiles: profiles)
  }

  @Test func hostMenuOffersOneSandboxRowPerProvider() {
    let hosts = NewSessionAdapter.hosts(catalog())
    #expect(hosts.map(\.name) == ["Modal Sandbox", "Agent_sandbox Sandbox"])
    #expect(hosts.allSatisfy { $0.kind == .cloud })
    #expect(NewSessionAdapter.sandboxProvider(hostID: hosts[1].id) == .some("agent_sandbox"))
    #expect(
      NewSessionAdapter.sandboxProvider(hostID: NewSessionAdapter.newSandboxHostID) == .some(nil))
    #expect(NewSessionAdapter.sandboxProvider(hostID: "host_a") == nil)
  }

  @Test func repositoriesFollowTheProvidersLimit() {
    var choices = SandboxChoices(
      provider: "modal",
      repos: [
        SandboxRepoChoice(url: "https://github.com/o/a"),
        SandboxRepoChoice(url: "https://github.com/o/b", branch: "dev"),
      ])
    #expect(choices.problem(catalog(), sandboxes: nil)?.contains("at most 1") == true)
    #expect(choices.repositoriesState(catalog(), sandboxes: nil).maxRepos == 1)
    choices.provider = "agent_sandbox"
    #expect(choices.problem(catalog(), sandboxes: nil) == nil)
    let target = choices.target(catalog())
    #expect(target.provider == "agent_sandbox")
    #expect(target.workspaces == ["https://github.com/o/a", "https://github.com/o/b#dev"])
    #expect(target.profile == nil)
  }

  @Test func profilesWaitForTheListWhenTheServerUsesThem() {
    let choices = SandboxChoices(provider: "modal")
    #expect(choices.profileProvider(catalog()) == nil)
    #expect(choices.profileProvider(catalog(profiles: true)) == "modal")
    #expect(choices.problem(catalog(profiles: true), sandboxes: nil) != nil)
    #expect(choices.profilesState(catalog(profiles: true), sandboxes: nil)?.isLoading == true)
  }

  @Test func aChosenProfileOffTheFirstPageIsCheckedAndShowsWhenItChanged() async throws {
    let page =
      #"{"profiles":[{"id":"p1","name":"GPU","description":"","provider":"modal","revision":"r2"}],"#
      + #""managed_providers":["modal"],"next_cursor":null}"#
    let connection = try await ConversationFixtures.connection(routes: [
      "/v1/sandbox-profiles": .json(page)
    ])
    let sandboxes = try #require(connection.sandboxes())
    await sandboxes.loadProfiles("modal")
    var choices = SandboxChoices(
      provider: "modal",
      profile: SandboxProfileOption(id: "p1", name: "GPU", revision: "r2"))
    let profiled = catalog(profiles: true)
    #expect(choices.problem(profiled, sandboxes: sandboxes) == nil, "listed at this revision")

    // Chosen at an older revision: the lookup says it changed.
    choices.profile = SandboxProfileOption(id: "p1", name: "GPU", revision: "r1")
    #expect(choices.problem(profiled, sandboxes: sandboxes) == "Loading sandbox profiles\u{2026}")
    await choices.checkChosenProfile(profiled, sandboxes: sandboxes)
    #expect(
      choices.problem(profiled, sandboxes: sandboxes)
        == "This profile changed or is unavailable. Choose a profile again before launching.")
    let state = try #require(choices.profilesState(profiled, sandboxes: sandboxes))
    #expect(state.isStale && state.label == "GPU (changed)")
  }

  @Test func archiveUndoWarnsOnlyAfterTheWorktreeGrace() {
    let undo = SidebarUndo(change: .archive(["conv_a"], true), removesWorktrees: true)
    #expect(undo.banner?.note != nil)
    #expect(undo.lostWorktreeWarning(now: undo.createdAt) == nil)
    #expect(undo.lostWorktreeWarning(now: undo.createdAt.addingTimeInterval(6)) != nil)
    let plain = SidebarUndo(change: .archive(["conv_a"], true))
    #expect(plain.banner?.note == nil)
    #expect(plain.lostWorktreeWarning(now: plain.createdAt.addingTimeInterval(60)) == nil)
  }
}
