import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// A custom agent made with Create Custom Agent and not saved: like the web, it is listed under
/// the agent picker's custom agents and uploads with the session on Start, so the server needs
/// no `agent_install`. A managed sandbox has no create path for an uploaded bundle.
extension NewSessionForm {
  /// The picker id of the unsaved agent.
  static let pendingAgentID = "omnigent.pending-custom-agent"

  /// Whether the unsaved agent is the selection.
  var startsPendingAgent: Bool {
    pendingAgent != nil && selection.agentId == Self.pendingAgentID
  }

  /// Selects a just-created unsaved agent.
  func adoptPendingAgent(_ draft: OmnigentCoreFFI.AgentDraft) {
    pendingAgent = draft
    isSandbox = false
    selection.agentId = Self.pendingAgentID
    selection.model = nil
    selection.reasoningEffort = nil
    selection.approvalMode = nil
    selection.planMode = false
  }

  /// The unsaved agent as a picker row.
  var pendingChoice: OmnigentUIComponents.HarnessChoice? {
    guard let pendingAgent, !isSandbox else { return nil }
    return OmnigentUIComponents.HarnessChoice(
      id: Self.pendingAgentID, name: pendingAgent.name, harness: pendingAgent.harness,
      builtin: false)
  }

  /// The unsaved agent as a catalog row, for the composer's labels.
  var pendingCreationAgent: OmnigentCoreFFI.CreationAgent? {
    guard let pendingAgent, selection.agentId == Self.pendingAgentID else { return nil }
    return OmnigentCoreFFI.CreationAgent(
      id: Self.pendingAgentID, name: pendingAgent.name, harness: pendingAgent.harness,
      description: pendingAgent.description.isEmpty ? nil : pendingAgent.description,
      harnessId: pendingAgent.harness, harnessLabel: pendingAgent.harness,
      supportsCreation: true, supportsModelPreview: false, builtin: false, mine: true,
      changedAt: nil, pickerSection: .custom, isPrimaryHarness: false, pickerRank: 0)
  }

  /// Why the unsaved agent cannot start yet: it needs an online host and a folder.
  func pendingAgentProblem(_ creation: CreationStore) -> String? {
    let host = creation.catalog.value?.hosts.first { $0.hostId == selection.hostId }
    if host?.isAvailable != true { return "Connect this host before starting a session." }
    if selection.workspace.isEmpty { return "Choose the folder the session works in." }
    return nil
  }
}
