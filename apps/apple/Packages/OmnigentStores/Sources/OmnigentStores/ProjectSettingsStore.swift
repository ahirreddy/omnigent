public import Observation
public import OmnigentCoreFFI

/// One project's Project settings sheet: its stored defaults, the hosts and agents to choose
/// from, the chosen agent's models, and the save.
@Observable
public final class ProjectSettingsStore {
  /// The project; a label-only one gains an id when saved.
  public private(set) var project: ProjectSummary
  /// The stored defaults.
  public private(set) var settings: CreationLoad<ProjectSettings> = .idle
  /// Hosts and agents.
  public private(set) var catalog: CreationLoad<CreationCatalog> = .idle
  /// The chosen agent's models on the chosen (or first online) host.
  public private(set) var models: CreationLoad<[ModelChoice]> = .idle
  /// Saving now.
  public private(set) var isSaving = false
  /// Why the last save failed.
  public private(set) var saveError: CoreError?

  private let core: ClientCore
  private var modelsGeneration = 0

  init(core: ClientCore, project: ProjectSummary) {
    self.core = core
    self.project = project
  }

  /// Loads the stored defaults and the catalog.
  public func load() async {
    settings = .loading
    catalog = .loading
    do {
      settings = .loaded(try await core.projectSettings(project: project))
    } catch {
      settings = .failed(coreError(error))
    }
    do {
      catalog = .loaded(try await core.creationCatalog())
    } catch {
      catalog = .failed(coreError(error))
    }
  }

  /// Loads `agentID`'s models on `hostID`; a newer request supersedes an older one.
  /// - Parameters:
  ///   - agentID: The agent, or `nil` for none (no models).
  ///   - hostID: The host to ask.
  public func loadModels(agentID: String?, hostID: String?) async {
    modelsGeneration += 1
    let generation = modelsGeneration
    guard let agentID, let hostID else {
      models = .idle
      return
    }
    models = .loading
    let result: CreationLoad<[ModelChoice]>
    do {
      result = .loaded(try await core.creationModels(agentId: agentID, hostId: hostID))
    } catch {
      result = .failed(coreError(error))
    }
    guard generation == modelsGeneration else { return }
    models = result
  }

  /// Saves `settings`, keeping any other stored keys.
  /// - Parameters:
  ///   - settings: The defaults.
  ///   - alwaysUseWorktree: Settings › Git's global worktree default.
  /// - Returns: Whether it saved.
  public func save(_ settings: ProjectSettings, alwaysUseWorktree: Bool) async -> Bool {
    guard case .loaded = self.settings, !isSaving else { return false }
    isSaving = true
    defer { isSaving = false }
    do {
      project = try await core.saveProjectSettings(
        project: project, settings: settings, alwaysUseWorktree: alwaysUseWorktree)
      saveError = nil
      return true
    } catch {
      saveError = coreError(error)
      return false
    }
  }
}

extension ConnectionStore {
  /// A store for `project`'s Project settings sheet.
  /// - Parameter project: The project.
  /// - Returns: The store, or `nil` when the core did not start.
  public func projectSettings(_ project: ProjectSummary) -> ProjectSettingsStore? {
    core.map { ProjectSettingsStore(core: $0, project: project) }
  }
}
