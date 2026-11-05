import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct ProjectSettingsAdapterTests {
  private func catalog(sandboxes: Bool = false) -> OmnigentCoreFFI.CreationCatalog {
    OmnigentCoreFFI.CreationCatalog(
      hosts: [
        CreationHost(
          hostId: "mac", name: "Mac", status: "online", sandboxProvider: nil,
          configuredHarnesses: nil, isAvailable: true),
        CreationHost(
          hostId: "box", name: "Box", status: "offline", sandboxProvider: nil,
          configuredHarnesses: nil, isAvailable: false),
      ],
      agents: [
        OmnigentCoreFFI.CreationAgent(
          id: "claude", name: "Claude Code", harness: "claude-native", description: nil,
          supportsCreation: true, pickerSection: .harness, isPrimaryHarness: true, pickerRank: 0)
      ],
      managedSandboxes: sandboxes)
  }

  private let models = [
    ModelChoice(
      id: "opus", model: "opus", displayName: nil, description: nil, hidden: nil, isDefault: true,
      defaultReasoningEffort: nil,
      supportedReasoningEfforts: [
        ReasoningChoice(reasoningEffort: "low", description: nil),
        ReasoningChoice(reasoningEffort: "high", description: nil),
      ], title: "Opus", value: "opus"),
    ModelChoice(
      id: "old", model: "old", displayName: nil, description: nil, hidden: true, isDefault: nil,
      defaultReasoningEffort: nil, supportedReasoningEfforts: nil, title: "Old", value: "old"),
  ]

  private static let empty = ProjectSettings(
    hostId: nil, workspace: nil, useWorktree: nil, baseBranch: nil, agentId: nil, model: nil,
    effort: nil)

  private func state(_ draft: ProjectSettingsDraft, sandboxes: Bool = false)
    -> ProjectSettingsViewState
  {
    ProjectSettingsAdapter.state(
      projectName: "Alpha", settings: .loaded(Self.empty),
      catalog: .loaded(catalog(sandboxes: sandboxes)), models: .loaded(models), draft: draft)
  }

  @Test func storedDefaultsFillTheFields() {
    let stored = ProjectSettings(
      hostId: "mac", workspace: "/repo", useWorktree: nil, baseBranch: "main", agentId: "claude",
      model: "opus", effort: "high")
    let draft = ProjectSettingsAdapter.draft(stored, alwaysUseWorktree: true)
    #expect(draft.hostID == "mac" && draft.workspace == "/repo" && draft.baseBranch == "main")
    // An unset worktree choice follows Settings › Git.
    #expect(draft.useWorktree)
    #expect(draft.agentID == "claude" && draft.model == "opus" && draft.effort == "high")
  }

  @Test func hostsAreOnlineOnesPlusTheSandboxAndAMissingStoredOne() {
    var draft = ProjectSettingsDraft()
    draft.hostID = "box"
    let offline = state(draft, sandboxes: true)
    #expect(offline.hosts.map(\.id) == [projectSandboxHostChoice(), "mac", "box"])
    #expect(offline.hosts.last?.title == "box (unavailable)")
    #expect(offline.hostTakesFolder)
    draft.hostID = projectSandboxHostChoice()
    #expect(!state(draft, sandboxes: true).hostTakesFolder)
    #expect(!state(ProjectSettingsDraft()).hosts.contains { $0.id == projectSandboxHostChoice() })
  }

  @Test func modelAndEffortFollowTheAgentAndModel() {
    var draft = ProjectSettingsDraft()
    #expect(!state(draft).showsModel && !state(draft).showsEffort)
    draft.agentID = "claude"
    let chosen = state(draft)
    #expect(chosen.showsModel && chosen.models.map(\.id) == ["opus"])
    // With no model chosen, the default model's efforts are offered.
    #expect(chosen.showsEffort && chosen.efforts.map(\.id) == ["low", "high"])
    draft.model = "retired"
    draft.effort = "max"
    let stored = state(draft)
    #expect(stored.models.last?.id == "retired")
    #expect(stored.efforts.map(\.id) == ["low", "high", "max"])
  }

  @Test func savingDropsFieldsTheSheetDoesNotShow() {
    var draft = ProjectSettingsDraft()
    draft.workspace = "/repo"
    draft.model = "opus"
    draft.effort = "high"
    let saved = ProjectSettingsAdapter.settings(draft, state: state(draft))
    #expect(saved.workspace == nil && saved.model == nil && saved.effort == nil)
    draft.hostID = "mac"
    draft.agentID = "claude"
    let kept = ProjectSettingsAdapter.settings(draft, state: state(draft))
    #expect(kept.workspace == "/repo" && kept.model == "opus" && kept.effort == "high")
    #expect(ProjectSettingsAdapter.modelHost(draft, catalog: catalog()) == "mac")
    draft.hostID = "box"
    #expect(ProjectSettingsAdapter.modelHost(draft, catalog: catalog()) == "mac")
  }
}
