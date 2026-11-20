import Foundation

/// Omni Advisor in Settings, as the web's `ProactiveAgentSettingControl` and
/// `ProactiveAgentAdminControls`: the caller's switch, and for admins the workspace switch, the
/// prompt every user's runs follow, and Run now.
nonisolated public struct AdvisorViewState: Hashable, Sendable {
  /// Where the settings stand.
  public enum Settings: Hashable, Sendable {
    /// Being read.
    case loading
    /// The first read failed.
    case failed
    /// Read.
    case ready(AdvisorSwitches)
  }

  /// Where the prompt stands (admins).
  public enum Prompt: Hashable, Sendable {
    /// Being read.
    case loading
    /// The read failed, with why.
    case failed(String)
    /// Read: the prompt in use and whether an admin replaced the built-in one.
    case ready(prompt: String, overridden: Bool)
  }

  /// The settings.
  public var settings: Settings
  /// A switch change is in flight.
  public var isSavingSwitch: Bool
  /// The last switch change the server refused, in its words.
  public var switchError: String?
  /// The prompt; `nil` for a caller who can't manage it.
  public var prompt: Prompt?
  /// A prompt save is in flight.
  public var isSavingPrompt: Bool
  /// The last prompt save the server refused.
  public var promptError: String?
  /// Run now is in flight.
  public var isRunning: Bool
  /// What the last Run now did, as the web says it.
  public var runSummary: String?
  /// Why the last Run now failed.
  public var runError: String?

  /// Creates the state.
  public init(
    settings: Settings, isSavingSwitch: Bool = false, switchError: String? = nil,
    prompt: Prompt? = nil, isSavingPrompt: Bool = false, promptError: String? = nil,
    isRunning: Bool = false, runSummary: String? = nil, runError: String? = nil
  ) {
    self.settings = settings
    self.isSavingSwitch = isSavingSwitch
    self.switchError = switchError
    self.prompt = prompt
    self.isSavingPrompt = isSavingPrompt
    self.promptError = promptError
    self.isRunning = isRunning
    self.runSummary = runSummary
    self.runError = runError
  }

  /// The admin's group shows unless the server says the caller can't manage the workspace;
  /// while the settings load it shows, as on the web.
  public var showsAdminControls: Bool {
    if case .ready(let switches) = settings { return switches.canManageWorkspace }
    return true
  }
}

/// The two switches as the server reports them.
nonisolated public struct AdvisorSwitches: Hashable, Sendable {
  /// The caller's switch reads on: theirs and the workspace's are both on.
  public var userOn: Bool
  /// The workspace lets it run.
  public var workspaceEnabled: Bool
  /// The caller may change the workspace switch.
  public var canManageWorkspace: Bool

  /// Creates the switches.
  public init(userOn: Bool, workspaceEnabled: Bool, canManageWorkspace: Bool) {
    self.userOn = userOn
    self.workspaceEnabled = workspaceEnabled
    self.canManageWorkspace = canManageWorkspace
  }
}

/// Whose switch a change flips.
nonisolated public enum AdvisorSwitch: Hashable, Sendable {
  /// The caller's own.
  case user
  /// Everyone's (admins).
  case workspace
}

/// What Omni Advisor's controls do.
public struct AdvisorActions {
  /// Flip a switch.
  public var setEnabled: (@MainActor (AdvisorSwitch, Bool) -> Void)?
  /// Read the settings again after a failure.
  public var retry: (@MainActor () -> Void)?
  /// Read the prompt again after a failure.
  public var retryPrompt: (@MainActor () -> Void)?
  /// Save the prompt for every user (`nil` restores the built-in one); returns the prompt now
  /// in use, or `nil` when the save failed.
  public var savePrompt: (@MainActor (String?) async -> String?)?
  /// Start runs now for the users typed (commas or spaces; `*` is everyone).
  public var run: (@MainActor (String) -> Void)?

  /// Creates actions; every one is optional.
  public init() {}
}
