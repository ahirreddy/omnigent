import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// A project chosen for the new session (from the sidebar's "New session in project" or the
/// page's project chip): the session is filed there, and the project's stored defaults (Project
/// settings: host or sandbox, folder, worktree, agent, model, effort) fill the form.
extension NewSessionForm {
  /// Files the session in `project` and applies its defaults once read.
  func applyProject(_ project: ProjectSummary, _ creation: CreationStore) async {
    self.project = project
    projectError = nil
    if creation.catalog.value == nil { await creation.loadCatalog() }
    switch await creation.projectSettings(project) {
    case .success(let settings):
      guard self.project == project else { return }
      apply(settings, creation)
    case .failure(let error):
      projectError = "Could not read \(project.name)'s defaults: \(error.message)"
    }
  }

  /// Files a just-created session in a label-only project, which the create cannot name.
  func fileInLabelProject(_ sessionID: String, list: SessionListStore) {
    guard let project, project.id == nil, filedSessionID != sessionID else { return }
    filedSessionID = sessionID
    // The move reports its own failure in the list's edit error.
    Task { _ = await list.move(sessionID, to: project) }
  }

  private func apply(_ settings: ProjectSettings, _ creation: CreationStore) {
    let catalog = creation.catalog.value
    if let agentID = settings.agentId, catalog?.agents.contains(where: { $0.id == agentID }) == true
    {
      selectAgent(agentID, creation)
    }
    if settings.hostId == projectSandboxHostChoice() {
      isSandbox = true
    } else if let hostID = settings.hostId,
      catalog?.hosts.contains(where: { $0.hostId == hostID }) == true
    {
      isSandbox = false
      chooseHost(hostID, creation)
    }
    change(creation) {
      if let model = settings.model { $0.model = model }
      if let effort = settings.effort { $0.reasoningEffort = effort }
    }
    guard !isSandbox else { return }
    if let workspace = settings.workspace, workspace.hasPrefix("/") {
      seededFolderHost = selection.hostId
      selectFolder(creation, workspace)
    }
    if settings.useWorktree == true {
      worktree = .new(
        branch: NewSessionAdapter.randomWorktreeBranch(), base: settings.baseBranch ?? "")
      applyWorktree()
    }
  }
}
