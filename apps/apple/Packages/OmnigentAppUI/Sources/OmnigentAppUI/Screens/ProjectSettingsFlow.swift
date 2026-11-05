import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// One open Project settings sheet: the store, the fields being edited, and the agent's models,
/// re-read when the agent or host changes.
@Observable
final class ProjectSettingsFlow: Identifiable {
  let id = UUID()
  let store: ProjectSettingsStore
  private(set) var draft = ProjectSettingsDraft()
  private let alwaysUseWorktree: Bool

  init(store: ProjectSettingsStore, alwaysUseWorktree: Bool) {
    self.store = store
    self.alwaysUseWorktree = alwaysUseWorktree
  }

  var state: ProjectSettingsViewState {
    var state = ProjectSettingsAdapter.state(
      projectName: store.project.name, settings: store.settings, catalog: store.catalog,
      models: store.models, draft: draft)
    state.isSaving = store.isSaving
    state.saveError = store.saveError?.message
    return state
  }

  /// The fields; picking another agent clears its model and effort, as the web.
  var draftBinding: Binding<ProjectSettingsDraft> {
    Binding(get: { self.draft }, set: { self.edit($0) })
  }

  /// Reads the stored settings and the catalog, fills in the fields, then lists the models.
  func load() async {
    await store.load()
    if let settings = store.settings.value {
      draft = ProjectSettingsAdapter.draft(settings, alwaysUseWorktree: alwaysUseWorktree)
    }
    await loadModels()
  }

  /// Saves the fields; returns whether they were saved.
  func save() async -> Bool {
    await store.save(
      ProjectSettingsAdapter.settings(draft, state: state), alwaysUseWorktree: alwaysUseWorktree)
  }

  private func edit(_ next: ProjectSettingsDraft) {
    guard next != draft else { return }
    var next = next
    let agentChanged = next.agentID != draft.agentID
    if agentChanged {
      next.model = nil
      next.effort = nil
    }
    let reloads = agentChanged || next.hostID != draft.hostID
    draft = next
    if reloads { Task { await loadModels() } }
  }

  private func loadModels() async {
    await store.loadModels(
      agentID: draft.agentID,
      hostID: ProjectSettingsAdapter.modelHost(draft, catalog: store.catalog.value))
  }
}
