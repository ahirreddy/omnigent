import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// New project from a repository or a folder on a host (`project_repository_creation`): where it
/// can run, and making it, as the web's New project dialog.
extension ConnectedServerView {
  /// The id prefix of a sandbox choice; the provider follows it.
  static let sandboxChoicePrefix = "__sandbox__:"

  /// The online hosts, then the sandboxes the server provisions; empty where the server offers
  /// no repository projects.
  var newProjectRunChoices: [ProjectRunChoice] {
    guard let pages = connection.pages?.offered, pages.projectRepositoryCreation,
      let catalog = connection.creationStore?.catalog.value
    else { return [] }
    var choices = catalog.hosts.filter { $0.isAvailable && $0.sandboxProvider == nil }
      .map { ProjectRunChoice(id: $0.hostId, title: $0.name) }
    if pages.managedSandboxes {
      choices += sandboxProviderOptions(catalog: catalog).map {
        ProjectRunChoice(
          id: Self.sandboxChoicePrefix + ($0.provider ?? ""), title: $0.label, isSandbox: true)
      }
    }
    return choices
  }

  /// The project's run target for a choice id.
  static func runTarget(_ choiceID: String) -> ProjectRunTarget {
    guard choiceID.hasPrefix(sandboxChoicePrefix) else { return .host(hostId: choiceID) }
    let provider = String(choiceID.dropFirst(sandboxChoicePrefix.count))
    return .sandbox(provider: provider.isEmpty ? nil : provider)
  }

  /// Making a project from a repository, where the server offers it.
  func repositoryProjectActions() -> ProjectCreationActions {
    var actions = ProjectCreationActions()
    guard connection.pages?.offered?.projectRepositoryCreation == true else { return actions }
    let connection = connection
    actions.create = { name, icon, draft in
      guard let target = draft.targetID else { return "Choose where to run the repository." }
      let made = await connection.sessionList.createRepositoryProject(
        RepositoryProjectRequest(
          name: name, icon: icon, target: Self.runTarget(target), url: draft.url,
          branch: draft.branch, destination: draft.destination))
      switch made {
      case .success: return nil
      case .failure(let error): return error.message
      }
    }
    actions.createFolderProject = { name, icon, draft in
      let hostID = draft.namesHost ? draft.targetID : nil
      let made = await connection.sessionList.createFolderProject(
        FolderProjectRequest(
          name: name, icon: icon, hostId: hostID,
          workspace: draft.workspace.isEmpty ? nil : draft.workspace))
      switch made {
      case .success: return nil
      case .failure(let error): return error.message
      }
    }
    actions.createFolder = { hostID, name in
      await connection.sessionList.createProjectFolder(hostID: hostID, name: name)
        .mapError { FolderBrowseError(message: $0.message) }
    }
    actions.browse = { hostID, path in
      guard let creation = connection.creation() else {
        return .failure(FolderBrowseError(message: "Connect to a server first."))
      }
      return await creation.directory(hostID: hostID, path: path)
        .map(NewSessionAdapter.listing)
        .mapError { FolderBrowseError(message: $0.message) }
    }
    actions.problem = { url, branch in projectRepositoryProblem(url: url, branch: branch) }
    actions.cloneDestination = { defaultCloneDestination(url: $0) }
    actions.loadChoices = {
      guard let creation = connection.creation(), creation.catalog.value == nil else { return }
      Task { await creation.loadCatalog() }
    }
    return actions
  }
}
