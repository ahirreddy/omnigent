import Foundation

/// How the sidebar orders projects (the projects header's "Sort projects by").
nonisolated public enum ProjectSort: String, Hashable, Sendable, CaseIterable {
  /// By name.
  case alphabetical
  /// The user's own order (drag, or Move).
  case manual

  /// The menu title.
  public var title: String {
    switch self {
    case .alphabetical: "Alphabetically"
    case .manual: "Manual order"
    }
  }
}

/// Where a project's Move submenu puts it.
nonisolated public enum ProjectMove: String, Hashable, Sendable, CaseIterable, Identifiable {
  /// One place up.
  case upOne
  /// One place down.
  case downOne
  /// First.
  case top
  /// Last.
  case bottom

  /// Stable id.
  public var id: String { rawValue }

  /// The menu title, in the web's words.
  public var title: String {
    switch self {
    case .upOne: "Move up"
    case .downOne: "Move down"
    case .top: "Move to top"
    case .bottom: "Move to bottom"
    }
  }
}

extension SessionProject {
  /// `projects` with the project `id` moved as `move` says (the web's `moveProject`); empty
  /// when it is missing or already there.
  public static func moved(_ projects: [Self], id: String, _ move: ProjectMove) -> [Self] {
    guard let from = projects.firstIndex(where: { $0.id == id }) else { return [] }
    let to =
      switch move {
      case .upOne: from - 1
      case .downOne: from + 1
      case .top: 0
      case .bottom: projects.count - 1
      }
    guard projects.indices.contains(to), to != from else { return [] }
    var result = projects
    result.insert(result.remove(at: from), at: to)
    return result
  }
}

/// One choice in a Project settings picker.
nonisolated public struct ProjectSettingsChoice: Hashable, Sendable, Identifiable {
  /// The stored value.
  public var id: String
  /// What the picker shows.
  public var title: String

  /// Creates a choice.
  public init(id: String, title: String) {
    self.id = id
    self.title = title
  }
}

/// The Project settings sheet's fields; `nil` and blank are no default.
nonisolated public struct ProjectSettingsDraft: Hashable, Sendable {
  /// The host id.
  public var hostID: String?
  /// The working directory on the host.
  public var workspace = ""
  /// Start each session in a fresh worktree.
  public var useWorktree = false
  /// The branch new worktrees fork from.
  public var baseBranch = ""
  /// The agent id.
  public var agentID: String?
  /// The model.
  public var model: String?
  /// The reasoning effort.
  public var effort: String?

  /// Creates an empty draft.
  public init() {}
}

/// The Project settings sheet (the web's `ProjectSettingsDialog`).
nonisolated public struct ProjectSettingsViewState: Hashable, Sendable {
  /// Whether the stored settings are loaded.
  public enum Phase: Hashable, Sendable {
    /// Reading them.
    case loading
    /// Ready to edit.
    case loaded
    /// They could not be read; saving is blocked so they are not overwritten.
    case failed(String)
  }

  /// The project's name.
  public var projectName: String
  /// Load state.
  public var phase: Phase
  /// Hosts to choose (online ones, the sandbox, and a stored host that is offline).
  public var hosts: [ProjectSettingsChoice] = []
  /// The chosen host is a machine (not the sandbox), so the folder field applies.
  public var hostTakesFolder = false
  /// Agents to choose.
  public var agents: [ProjectSettingsChoice] = []
  /// The Model field shows: the chosen agent's host lists models, or one is stored.
  public var showsModel = false
  /// The chosen agent's models.
  public var models: [ProjectSettingsChoice] = []
  /// The Effort field shows: the chosen model has effort levels, or one is stored.
  public var showsEffort = false
  /// The chosen model's effort levels.
  public var efforts: [ProjectSettingsChoice] = []
  /// A save is in flight.
  public var isSaving = false
  /// Why the last save failed.
  public var saveError: String?

  /// Creates the state.
  public init(projectName: String, phase: Phase) {
    self.projectName = projectName
    self.phase = phase
  }
}

/// The Project settings sheet's actions.
public struct ProjectSettingsActions {
  /// Saves the draft; the host closes the sheet once it is saved.
  public var save: @MainActor () -> Void
  /// Closes without saving.
  public var cancel: @MainActor () -> Void

  /// Creates actions.
  public init(save: @escaping @MainActor () -> Void, cancel: @escaping @MainActor () -> Void) {
    self.save = save
    self.cancel = cancel
  }
}
