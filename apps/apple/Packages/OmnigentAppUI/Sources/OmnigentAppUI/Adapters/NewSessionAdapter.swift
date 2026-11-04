import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps the core's creation catalog and the new-session form's choices to the composer and the
/// start options, the way the web's new-session page lays them out.
enum NewSessionAdapter {
  /// The Host menu's entry for a new sandbox the server provisions.
  static let newSandboxHostID = "omnigent.new-sandbox"

  /// The agent picker rows in the web's order (primary harnesses, other harnesses, built-in
  /// agents, the user's own) and each row's group.
  /// - Parameters:
  ///   - catalog: The creation catalog.
  ///   - hostID: The selected host, for readiness.
  /// - Returns: The rows and their groups.
  static func agents(
    _ catalog: OmnigentCoreFFI.CreationCatalog, hostID: String
  ) -> (choices: [OmnigentUIComponents.HarnessChoice], groups: [String: AgentPickerGroup]) {
    let creatable = catalog.agents.filter(\.supportsCreation)
    let grouped = creatable.enumerated().map { index, agent in
      (index: index, agent: agent, group: group(agent))
    }
    let sorted = grouped.sorted { first, second in
      let firstRank = (order(first.group), first.agent.pickerRank, first.index)
      let secondRank = (order(second.group), second.agent.pickerRank, second.index)
      return firstRank < secondRank
    }
    let choices = sorted.map { entry in
      OmnigentUIComponents.HarnessChoice(
        id: entry.agent.id, name: entry.agent.name, harness: entry.agent.harness,
        builtin: entry.agent.builtin,
        unavailableReason: hostID == newSandboxHostID
          ? nil
          : creationUnavailableReason(catalog: catalog, agentId: entry.agent.id, hostId: hostID))
    }
    let groups = Dictionary(uniqueKeysWithValues: sorted.map { ($0.agent.id, $0.group) })
    return (choices, groups)
  }

  static func group(_ agent: OmnigentCoreFFI.CreationAgent) -> AgentPickerGroup {
    switch agent.pickerSection {
    case .harness: agent.isPrimaryHarness ? .harness : .otherHarness
    case .agent: .agent
    case .custom: .custom
    }
  }

  private static func order(_ group: AgentPickerGroup) -> Int {
    switch group {
    case .harness: 0
    case .otherHarness: 1
    case .agent: 2
    case .custom: 3
    }
  }

  /// The Host menu: the server's hosts, then "New Sandbox" when it provisions them.
  static func hosts(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> [ComposerHost] {
    var hosts = (catalog?.hosts ?? []).map { host in
      ComposerHost(
        id: host.hostId, name: ExecutionContext.hostDisplayName(host.name) ?? host.hostId,
        kind: host.sandboxProvider == nil ? .machine : .cloud, isOnline: host.isAvailable)
    }
    if catalog?.managedSandboxes == true {
      hosts.insert(
        ComposerHost(id: newSandboxHostID, name: "New Sandbox", kind: .cloud, isOnline: true),
        at: 0)
    }
    return hosts
  }

  /// The approval modes the selected agent can start in, with `selected` (or its default).
  static func approvalModes(
    _ agent: OmnigentCoreFFI.CreationAgent?, selected: String?
  ) -> ApprovalModes? {
    guard let agent, let menu = creationApprovalModeMenu(agent: agent) else { return nil }
    var modes = ComposerAdapter.approvalModes(menu)
    modes.selectedID = selected ?? menu.selected
    return modes
  }

  /// The selection's approval mode for `option`: `nil` for the harness default.
  static func approvalMode(
    _ option: OmnigentUIComponents.ApprovalModeOption, agent: OmnigentCoreFFI.CreationAgent?
  ) -> String? {
    let defaultMode = agent.flatMap { creationApprovalModeMenu(agent: $0)?.selected }
    return option.id == defaultMode ? nil : option.id
  }

  /// The `git` block and workspace for a worktree choice in `folder`.
  static func git(
    _ choice: NewSessionWorktreeChoice, folder: String
  ) -> (git: OmnigentCoreFFI.CreationGit?, workspace: String) {
    switch choice {
    case .none:
      return (nil, folder)
    case .new(let branch, let base):
      return (
        CreationGit(
          branchName: branch, baseBranch: base.isEmpty ? nil : base, existingWorktree: false),
        folder
      )
    case .existing(let worktree):
      return (
        worktree.branch.map { CreationGit(branchName: $0, existingWorktree: true) },
        worktree.path
      )
    }
  }

  /// Existing worktrees to offer: the repository's linked worktrees, main excluded.
  static func worktrees(_ worktrees: [HostWorktree]) -> [NewSessionWorktreeOption] {
    worktrees.filter { !$0.isMain }.map {
      NewSessionWorktreeOption(path: $0.path, branch: $0.branch)
    }
  }

  /// A host directory listing for the folder browser.
  static func listing(_ listing: HostDirectoryListing) -> FolderListing {
    FolderListing(
      path: listing.path, parent: listing.parent,
      folders: listing.directories.map { FolderListing.Entry(path: $0.path, name: $0.name) })
  }

  /// The model rows for the picker.
  static func models(_ choices: [ModelChoice]) -> [OmnigentUIComponents.ModelOption] {
    choices.filter { $0.hidden != true }.map { choice in
      OmnigentUIComponents.ModelOption(
        id: choice.value, model: choice.model, displayName: choice.title,
        defaultReasoningEffort: choice.defaultReasoningEffort,
        supportedReasoningEfforts: (choice.supportedReasoningEfforts ?? []).map(\.reasoningEffort),
        isDefault: choice.isDefault ?? false, hidden: false)
    }
  }
}
