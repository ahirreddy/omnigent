import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The sidebar's project actions: create, rename and icon, delete, order and sort, New session
/// in a project, and Project settings.
extension ConnectedServerView {
  func withProjectActions(_ actions: SidebarActions) -> SidebarActions {
    var actions = actions
    let list = connection.sessionList
    actions.createProject = { name, icon, moving in
      Task {
        guard let project = await list.createProject(named: name, icon: icon), let moving else {
          return
        }
        await list.move(moving.id, to: project)
      }
    }
    actions.renameProject = { project, name, icon in
      Task { await list.editProject(ProjectSummary(project), name: name, icon: icon) }
    }
    actions.deleteProject = { project in
      Task { await list.deleteProject(ProjectSummary(project)) }
    }
    actions.reorderProjects = { projects in
      Task { await list.saveProjectOrder(projects.map(ProjectSummary.init)) }
    }
    actions.setProjectSort = { sort in
      Task {
        await list.setProjectSortMode(
          sort == .manual ? .manual : .alphabetical, projects: list.projects)
      }
    }
    actions.newSessionInProject = { project in newSession(in: project) }
    actions.openProjectSettings = { project in openProjectSettings(project) }
    return actions
  }

  /// Opens New session filed into `project`: the form reads ``CreationStore/pendingProject``.
  func newSession(in project: SessionProject) {
    connection.creation()?.pendingProject = ProjectSummary(project)
    selectionBinding.wrappedValue = .newSession
  }

  func openProjectSettings(_ project: SessionProject) {
    guard let store = connection.projectSettings(ProjectSummary(project)) else { return }
    sidebarModel.projectSettings = ProjectSettingsFlow(
      store: store,
      alwaysUseWorktree: UserDefaults.standard.bool(forKey: GitPreferences.alwaysUseWorktreeKey))
  }

  /// The open Project settings sheet; saving re-reads the projects (a label-only one gains an
  /// id) and closes it.
  func projectSettingsSheet(_ flow: ProjectSettingsFlow) -> some View {
    let model = sidebarModel
    let list = connection.sessionList
    return ProjectSettingsSheet(
      state: flow.state, draft: flow.draftBinding,
      actions: ProjectSettingsActions(
        save: {
          Task {
            guard await flow.save() else { return }
            await list.loadProjects()
            model.projectSettings = nil
          }
        },
        cancel: { model.projectSettings = nil })
    )
    .task { await flow.load() }
  }
}
