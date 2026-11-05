import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct NewSessionAdapterTests {
  private func agent(
    _ id: String, harness: String, section: AgentPickerSection, primary: Bool = false,
    rank: UInt32 = 3
  ) -> OmnigentCoreFFI.CreationAgent {
    OmnigentCoreFFI.CreationAgent(
      id: id, name: id, harness: harness, description: nil, supportsCreation: true,
      pickerSection: section, isPrimaryHarness: primary, pickerRank: rank)
  }

  private func catalog(sandboxes: Bool = false) -> OmnigentCoreFFI.CreationCatalog {
    OmnigentCoreFFI.CreationCatalog(
      hosts: [
        CreationHost(
          hostId: "host_a", name: "Mac", status: "online", sandboxProvider: nil,
          configuredHarnesses: nil, isAvailable: true)
      ],
      agents: [
        agent("mock-model", harness: "openai-agents", section: .custom),
        agent("polly", harness: "claude-sdk", section: .agent),
        agent("pi", harness: "pi-native", section: .harness),
        agent("codex", harness: "codex-native", section: .harness, primary: true, rank: 2),
        agent("claude", harness: "claude-native", section: .harness, primary: true, rank: 0),
      ],
      managedSandboxes: sandboxes)
  }

  @Test func agentsFollowTheWebGroupsAndOrder() {
    let result = NewSessionAdapter.agents(catalog(), hostID: "host_a")
    #expect(result.choices.map(\.id) == ["claude", "codex", "pi", "polly", "mock-model"])
    #expect(result.groups["claude"] == .harness)
    #expect(result.groups["pi"] == .otherHarness)
    #expect(result.groups["polly"] == .agent)
    #expect(result.groups["mock-model"] == .custom)
  }

  @Test func hidingUnconfiguredKeepsAgentsAndTheSelectedHarness() {
    var limited = catalog()
    limited.hosts[0].configuredHarnesses = [
      HarnessStatus(harness: "claude-native", readiness: .ready),
      HarnessStatus(harness: "codex-native", readiness: .notReady),
      HarnessStatus(harness: "pi-native", readiness: .notReady),
    ]
    let badged = NewSessionAdapter.agents(limited, hostID: "host_a").choices
    let unconfigured = badged.filter { $0.unavailableReason != nil }.map(\.id)
    #expect(unconfigured.contains("codex") && unconfigured.contains("pi"))
    let hidden = NewSessionAdapter.agents(limited, hostID: "host_a", hidingUnconfigured: "pi")
    let shown = hidden.choices.map(\.id)
    #expect(!shown.contains("codex"), "an unconfigured harness is hidden")
    #expect(shown.contains("pi"), "the selected harness stays")
    #expect(shown.contains("claude") && shown.contains("polly") && shown.contains("mock-model"))
  }

  @Test func newSandboxIsOfferedOnlyWhenTheServerProvisionsThem() {
    #expect(
      !NewSessionAdapter.hosts(catalog()).contains { $0.id == NewSessionAdapter.newSandboxHostID })
    let hosts = NewSessionAdapter.hosts(catalog(sandboxes: true))
    #expect(hosts.first?.id == NewSessionAdapter.newSandboxHostID)
    #expect(hosts.first?.kind == .cloud)
    // A sandbox needs no host readiness, so no agent is marked unavailable there.
    let rows = NewSessionAdapter.agents(catalog(), hostID: NewSessionAdapter.newSandboxHostID)
    #expect(rows.choices.allSatisfy { $0.unavailableReason == nil })
  }

  @Test func worktreeChoicesBecomeTheGitBlockAndWorkspace() {
    #expect(NewSessionAdapter.git(.none, folder: "/r").git == nil)
    let created = NewSessionAdapter.git(.new(branch: "feat", base: ""), folder: "/r")
    #expect(
      created.git == CreationGit(branchName: "feat", baseBranch: nil, existingWorktree: false))
    #expect(created.workspace == "/r")
    let existing = NewSessionAdapter.git(
      .existing(NewSessionWorktreeOption(path: "/r-wt", branch: "wt")), folder: "/r")
    #expect(existing.git == CreationGit(branchName: "wt", existingWorktree: true))
    #expect(existing.workspace == "/r-wt")
    let detached = NewSessionAdapter.git(
      .existing(NewSessionWorktreeOption(path: "/r-d", branch: nil)), folder: "/r")
    #expect(detached.git == nil)
    #expect(detached.workspace == "/r-d")
  }

  @Test func launchApprovalModesDefaultToTheHarnessDefault() {
    let claude = agent("claude", harness: "claude-native", section: .harness)
    let modes = NewSessionAdapter.approvalModes(claude, selected: nil)
    #expect(modes?.selectedID == "default")
    #expect(modes?.options.contains { $0.id == "bypassPermissions" } == true)
    let bypass = modes?.options.first { $0.id == "bypassPermissions" }
    #expect(
      bypass.flatMap { NewSessionAdapter.approvalMode($0, agent: claude) } == "bypassPermissions")
    let ask = modes?.options.first { $0.id == "default" }
    #expect(ask.flatMap { NewSessionAdapter.approvalMode($0, agent: claude) } == nil)
    let piAgent = agent("pi", harness: "pi", section: .agent)
    #expect(NewSessionAdapter.approvalModes(piAgent, selected: nil) == nil)
  }

  @Test func worktreesHideTheMainCheckout() {
    let rows = NewSessionAdapter.worktrees([
      HostWorktree(path: "/r", branch: "main", isMain: true),
      HostWorktree(path: "/r-wt", branch: "wt", isMain: false),
    ])
    #expect(rows == [NewSessionWorktreeOption(path: "/r-wt", branch: "wt")])
  }
}
