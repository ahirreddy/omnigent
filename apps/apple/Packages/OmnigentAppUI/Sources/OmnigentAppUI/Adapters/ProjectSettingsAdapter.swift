import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps a project's stored defaults and the catalog to the Project settings sheet, as the web's
/// `ProjectSettingsDialog`: online hosts (and the sandbox when the server offers one), a stored
/// choice that is no longer offered kept as its own item so saving does not drop it, and Model
/// and Effort only for an agent whose host lists models.
enum ProjectSettingsAdapter {
  /// The sheet's fields for `settings`; an unset worktree choice follows `alwaysUseWorktree`.
  static func draft(_ settings: ProjectSettings, alwaysUseWorktree: Bool) -> ProjectSettingsDraft {
    var draft = ProjectSettingsDraft()
    draft.hostID = settings.hostId
    draft.workspace = settings.workspace ?? ""
    draft.useWorktree = settings.useWorktree ?? alwaysUseWorktree
    draft.baseBranch = settings.baseBranch ?? ""
    draft.agentID = settings.agentId
    draft.model = settings.model
    draft.effort = settings.effort
    return draft
  }

  /// What to save: Model and Effort only while the sheet offers them.
  static func settings(_ draft: ProjectSettingsDraft, state: ProjectSettingsViewState)
    -> ProjectSettings
  {
    ProjectSettings(
      hostId: draft.hostID, workspace: state.hostTakesFolder ? draft.workspace : nil,
      useWorktree: draft.useWorktree, baseBranch: draft.baseBranch, agentId: draft.agentID,
      model: state.showsModel ? draft.model : nil, effort: state.showsEffort ? draft.effort : nil)
  }

  /// The host to list the agent's models on: the chosen machine, else the first online one.
  static func modelHost(
    _ draft: ProjectSettingsDraft, catalog: OmnigentCoreFFI.CreationCatalog?
  ) -> String? {
    let online = catalog?.hosts.filter(\.isAvailable).map(\.hostId) ?? []
    if let host = draft.hostID, online.contains(host) { return host }
    return online.first
  }

  /// The sheet's state.
  static func state(
    projectName: String, settings: CreationLoad<ProjectSettings>,
    catalog: CreationLoad<OmnigentCoreFFI.CreationCatalog>, models: CreationLoad<[ModelChoice]>,
    draft: ProjectSettingsDraft
  ) -> ProjectSettingsViewState {
    let phase: ProjectSettingsViewState.Phase =
      switch settings {
      case .idle, .loading: .loading
      case .loaded: .loaded
      case .failed(let error): .failed(error.message)
      }
    var state = ProjectSettingsViewState(projectName: projectName, phase: phase)
    let sandbox = projectSandboxHostChoice()
    var hosts = (catalog.value?.hosts ?? []).filter(\.isAvailable).map {
      ProjectSettingsChoice(id: $0.hostId, title: $0.name)
    }
    if catalog.value?.managedSandboxes == true {
      hosts.insert(ProjectSettingsChoice(id: sandbox, title: "Sandbox"), at: 0)
    }
    state.hosts = keeping(draft.hostID, in: hosts, unavailable: true)
    state.hostTakesFolder = draft.hostID.map { !$0.hasPrefix(sandbox) } ?? false
    let creatable = (catalog.value?.agents ?? []).filter(\.supportsCreation)
    let agents = PickerVisibilityAdapter.shown(creatable, selectedID: draft.agentID).map {
      ProjectSettingsChoice(id: $0.id, title: $0.name)
    }
    state.agents = keeping(draft.agentID, in: agents, unavailable: true)
    guard draft.agentID != nil else { return state }
    let listed = (models.value ?? []).filter { $0.hidden != true }
    let modelChoices = listed.map { ProjectSettingsChoice(id: $0.value, title: $0.title) }
    state.showsModel = !modelChoices.isEmpty || draft.model != nil
    state.models = keeping(draft.model, in: modelChoices, unavailable: false)
    let model = listed.first { $0.value == draft.model } ?? listed.first { $0.isDefault == true }
    let efforts = (model?.supportedReasoningEfforts ?? []).map {
      ProjectSettingsChoice(id: $0.reasoningEffort, title: $0.reasoningEffort.capitalized)
    }
    state.showsEffort = !efforts.isEmpty || draft.effort != nil
    state.efforts = keeping(draft.effort, in: efforts, unavailable: false)
    return state
  }

  /// `choices` plus `stored` when it is not among them.
  private static func keeping(
    _ stored: String?, in choices: [ProjectSettingsChoice], unavailable: Bool
  ) -> [ProjectSettingsChoice] {
    guard let stored, !choices.contains(where: { $0.id == stored }) else { return choices }
    return choices + [
      ProjectSettingsChoice(id: stored, title: unavailable ? "\(stored) (unavailable)" : stored)
    ]
  }
}
