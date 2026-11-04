public import Foundation

/// What the composer is for.
nonisolated public enum ComposerPurpose: Hashable, Sendable {
  /// Sending to an existing session.
  case session
  /// Starting a new session: Send reads "Start session".
  case start
}

/// One host in the Host chip's menu.
nonisolated public struct ComposerHost: Hashable, Sendable, Identifiable {
  /// Where it runs.
  public enum Kind: Hashable, Sendable {
    /// A managed cloud sandbox.
    case cloud
    /// One of the user's machines.
    case machine
  }

  /// Host id.
  public var id: String
  /// Display name.
  public var name: String
  /// Cloud or machine.
  public var kind: Kind
  /// Online.
  public var isOnline: Bool

  /// Creates a host.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - kind: Kind.
  ///   - isOnline: Online.
  public init(id: String, name: String, kind: Kind, isOnline: Bool) {
    self.id = id
    self.name = name
    self.kind = kind
    self.isOnline = isOnline
  }
}

/// The Host chip: the hosts offered and the selected one.
nonisolated public struct ComposerHosts: Hashable, Sendable {
  /// Hosts, in any order; the menu groups them into Cloud, My machines and Offline hosts.
  public var hosts: [ComposerHost]
  /// The selected host id.
  public var selectedID: String?
  /// The host can only change on a new session.
  public var isLocked: Bool

  /// Creates the chip state.
  /// - Parameters:
  ///   - hosts: Hosts.
  ///   - selectedID: Selected host.
  ///   - isLocked: Fixed for this session.
  public init(hosts: [ComposerHost], selectedID: String?, isLocked: Bool = false) {
    self.hosts = hosts
    self.selectedID = selectedID
    self.isLocked = isLocked
  }

  /// The selected host.
  public var selected: ComposerHost? { hosts.first { $0.id == selectedID } }
}

/// How much an approval mode lets the agent do without asking, lowest first (the core's
/// `ApprovalRisk`).
nonisolated public enum ApprovalRisk: Int, Hashable, Sendable, Comparable, CaseIterable {
  /// Reads and plans only.
  case readOnly
  /// Asks before edits and commands.
  case ask
  /// Applies edits without asking.
  case autoEdit
  /// Runs what it judges safe without asking.
  case autoApprove
  /// Runs everything without asking.
  case fullAccess

  /// Lower risk first.
  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

  /// A shield-family symbol.
  public var systemImage: String {
    switch self {
    case .readOnly: "lock.shield"
    case .ask: "shield"
    case .autoEdit: "shield.lefthalf.filled"
    case .autoApprove: "checkmark.shield"
    case .fullAccess: "shield.slash"
    }
  }
}

/// One approval mode the harness offers.
nonisolated public struct ApprovalModeOption: Hashable, Sendable, Identifiable {
  /// The wire value.
  public var id: String
  /// The clear name, for example "Ask first", "Auto-edit", "Full access".
  public var label: String
  /// What it allows, for the menu and the ⇧Tab HUD.
  public var detail: String?
  /// The harness's own name, for example Codex's "Approve for me".
  public var harnessLabel: String?
  /// How much it allows; picks the symbol and tint.
  public var risk: ApprovalRisk
  /// A running session can be switched into it; launch-only modes are shown, never offered.
  public var isSwitchable: Bool

  /// Creates a mode.
  /// - Parameters:
  ///   - id: Wire value.
  ///   - label: Clear name.
  ///   - detail: What it allows.
  ///   - harnessLabel: The harness's own name.
  ///   - risk: How much it allows.
  ///   - isSwitchable: Can be switched into.
  public init(
    id: String, label: String, detail: String? = nil, harnessLabel: String? = nil,
    risk: ApprovalRisk = .ask, isSwitchable: Bool = true
  ) {
    self.id = id
    self.label = label
    self.detail = detail
    self.harnessLabel = harnessLabel
    self.risk = risk
    self.isSwitchable = isSwitchable
  }
}

/// The approval-mode chip: the harness's modes and the current one. Separate from sandbox
/// scope and from the model.
nonisolated public struct ApprovalModes: Hashable, Sendable {
  /// The menu header, for example "Codex approvals".
  public var title: String
  /// Modes, in the harness's order.
  public var options: [ApprovalModeOption]
  /// The selected mode id; `nil` when the session has not reported one.
  public var selectedID: String?

  /// Creates the chip state.
  /// - Parameters:
  ///   - title: Menu header.
  ///   - options: Modes.
  ///   - selectedID: Selected mode.
  public init(title: String = "Approvals", options: [ApprovalModeOption], selectedID: String?) {
    self.title = title
    self.options = options
    self.selectedID = selectedID
  }

  /// The selected mode.
  public var selected: ApprovalModeOption? { options.first { $0.id == selectedID } }

  /// The switchable mode after the selected one, wrapping (⇧Tab). `nil` when the current mode
  /// is unknown or launch-only: leaving it stays a menu choice (the core's rule).
  public var next: ApprovalModeOption? {
    guard let current = selected, current.isSwitchable else { return nil }
    let switchable = options.filter(\.isSwitchable)
    guard let index = switchable.firstIndex(where: { $0.id == current.id }) else { return nil }
    let next = switchable[(index + 1) % switchable.count]
    return next.id == current.id ? nil : next
  }
}

/// The context tray above the composer card.
nonisolated public struct ComposerTray: Hashable, Sendable {
  /// The working directory label.
  public var directory: String?
  /// Recent directories for the directory chip.
  public var recentDirectories: [String]
  /// The worktree or branch label ("No worktree" when none).
  public var worktree: String?
  /// Existing worktrees offered.
  public var worktrees: [String]
  /// The branch in a session.
  public var branch: String?
  /// A linked pull request label, for example "#1234".
  public var pullRequest: String?
  /// Context window used, 0 to 1.
  public var contextFraction: Double?

  /// Creates a tray.
  /// - Parameters:
  ///   - directory: Directory.
  ///   - recentDirectories: Recents.
  ///   - worktree: Worktree.
  ///   - worktrees: Worktrees.
  ///   - branch: Branch.
  ///   - pullRequest: PR label.
  ///   - contextFraction: Context use.
  public init(
    directory: String? = nil, recentDirectories: [String] = [], worktree: String? = nil,
    worktrees: [String] = [], branch: String? = nil, pullRequest: String? = nil,
    contextFraction: Double? = nil
  ) {
    self.directory = directory
    self.recentDirectories = recentDirectories
    self.worktree = worktree
    self.worktrees = worktrees
    self.branch = branch
    self.pullRequest = pullRequest
    self.contextFraction = contextFraction
  }
}

/// A command or skill for the `/` menu.
nonisolated public struct SlashCommand: Hashable, Sendable, Identifiable {
  /// The name without the prefix.
  public var name: String
  /// What is typed before the name: `/`, or `$` for Codex skills.
  public var prefix: String
  /// One line.
  public var description: String
  /// A skill rather than a command.
  public var isSkill: Bool

  /// The typed form, for example `/compact`.
  public var id: String { prefix + name }

  /// Creates a command.
  /// - Parameters:
  ///   - name: Name.
  ///   - prefix: The typed prefix.
  ///   - description: Description.
  ///   - isSkill: Skill.
  public init(name: String, prefix: String = "/", description: String = "", isSkill: Bool = false) {
    self.name = name
    self.prefix = prefix
    self.description = description
    self.isSkill = isSkill
  }
}

/// The session's live connection, shown under the composer when it is not live.
nonisolated public struct ComposerConnectionNotice: Hashable, Sendable {
  /// What is wrong, for example "Reconnecting in 4s: network lost".
  public var message: String
  /// The connection failed or stopped, rather than recovering by itself.
  public var isFailure: Bool

  /// Creates a notice.
  /// - Parameters:
  ///   - message: The line.
  ///   - isFailure: Failed rather than recovering.
  public init(message: String, isFailure: Bool = false) {
    self.message = message
    self.isFailure = isFailure
  }
}

/// A message queued (or steering) while the agent works.
nonisolated public struct QueuedMessage: Hashable, Sendable, Identifiable {
  /// Its state.
  public enum State: Hashable, Sendable {
    /// Waiting for the turn to end.
    case queued
    /// Being sent.
    case sending
    /// "Waiting for host".
    case waitingForHost
    /// "Send failed".
    case failed(message: String)
  }

  /// Stable id.
  public var id: String
  /// The text.
  public var text: String
  /// State.
  public var state: State

  /// Creates a queued message.
  /// - Parameters:
  ///   - id: Id.
  ///   - text: Text.
  ///   - state: State.
  public init(id: String, text: String, state: State = .queued) {
    self.id = id
    self.text = text
    self.state = state
  }
}

/// Composer actions beyond send and stop. `nil` hides the control.
public struct ComposerExtraActions {
  /// Choose a host.
  public var selectHost: (@MainActor (ComposerHost) -> Void)?
  /// Connect a new host.
  public var connectHost: (@MainActor () -> Void)?
  /// Choose an approval mode.
  public var selectApprovalMode: (@MainActor (ApprovalModeOption) -> Void)?
  /// Start dictation (⌘⌥V).
  public var dictate: (@MainActor () -> Void)?
  /// Choose a working directory.
  public var selectDirectory: (@MainActor (String) -> Void)?
  /// Open a folder (on this Mac).
  public var openFolder: (@MainActor () -> Void)?
  /// Choose a worktree (`nil` for none).
  public var selectWorktree: (@MainActor (String?) -> Void)?
  /// Start a side chat (Add menu).
  public var newSideChat: (@MainActor () -> Void)?
  /// Set a goal (Add menu).
  public var setGoal: (@MainActor () -> Void)?
  /// Toggle plan mode (Add menu); the current value.
  public var togglePlan: (@MainActor () -> Void)?
  /// Plan mode is on.
  public var isPlanOn: Bool
  /// Edit a queued message.
  public var editQueued: (@MainActor (QueuedMessage, String) -> Void)?
  /// Send a queued message now.
  public var sendQueuedNow: (@MainActor (QueuedMessage) -> Void)?
  /// Remove a queued message.
  public var removeQueued: (@MainActor (QueuedMessage) -> Void)?
  /// Reorder queued messages.
  public var moveQueued: (@MainActor (IndexSet, Int) -> Void)?
  /// Recall the previous prompt into an empty field (Up arrow).
  public var recallPrevious: (@MainActor () -> String?)?
  /// Queue the draft to send after the current turn, instead of steering it in now.
  public var queueDraft: (@MainActor () -> Void)?
  /// Reconnect the session's stream (the connection notice's button).
  public var reconnect: (@MainActor () -> Void)?
  /// Dismiss the output of a local command (`/help`, usage).
  public var dismissCommandNotice: (@MainActor () -> Void)?
  /// "Create custom agent…" under the agent picker's custom agents (a new session only).
  public var createAgent: (@MainActor () -> Void)?
  /// "Import bundle…" under the agent picker's custom agents (a new session only).
  public var importAgentBundle: (@MainActor () -> Void)?

  /// Creates actions.
  /// - Parameters:
  ///   - selectHost: Choose a host.
  ///   - connectHost: Connect a host.
  ///   - selectApprovalMode: Choose a mode.
  ///   - dictate: Dictation.
  ///   - selectDirectory: Choose a directory.
  ///   - openFolder: Open a folder.
  ///   - selectWorktree: Choose a worktree.
  ///   - newSideChat: Side chat.
  ///   - setGoal: Goal.
  ///   - togglePlan: Plan mode.
  ///   - isPlanOn: Plan mode on.
  ///   - editQueued: Edit queued.
  ///   - sendQueuedNow: Send now.
  ///   - removeQueued: Remove.
  ///   - moveQueued: Reorder.
  ///   - recallPrevious: Up-arrow recall.
  ///   - queueDraft: Queue the draft after this turn.
  ///   - reconnect: Reconnect the stream.
  ///   - dismissCommandNotice: Dismiss a command's output.
  ///   - createAgent: Create a custom agent.
  ///   - importAgentBundle: Import an agent bundle.
  public init(
    selectHost: (@MainActor (ComposerHost) -> Void)? = nil,
    connectHost: (@MainActor () -> Void)? = nil,
    selectApprovalMode: (@MainActor (ApprovalModeOption) -> Void)? = nil,
    dictate: (@MainActor () -> Void)? = nil,
    selectDirectory: (@MainActor (String) -> Void)? = nil,
    openFolder: (@MainActor () -> Void)? = nil,
    selectWorktree: (@MainActor (String?) -> Void)? = nil,
    newSideChat: (@MainActor () -> Void)? = nil, setGoal: (@MainActor () -> Void)? = nil,
    togglePlan: (@MainActor () -> Void)? = nil, isPlanOn: Bool = false,
    editQueued: (@MainActor (QueuedMessage, String) -> Void)? = nil,
    sendQueuedNow: (@MainActor (QueuedMessage) -> Void)? = nil,
    removeQueued: (@MainActor (QueuedMessage) -> Void)? = nil,
    moveQueued: (@MainActor (IndexSet, Int) -> Void)? = nil,
    recallPrevious: (@MainActor () -> String?)? = nil,
    queueDraft: (@MainActor () -> Void)? = nil,
    reconnect: (@MainActor () -> Void)? = nil,
    dismissCommandNotice: (@MainActor () -> Void)? = nil,
    createAgent: (@MainActor () -> Void)? = nil,
    importAgentBundle: (@MainActor () -> Void)? = nil
  ) {
    self.selectHost = selectHost
    self.connectHost = connectHost
    self.selectApprovalMode = selectApprovalMode
    self.dictate = dictate
    self.selectDirectory = selectDirectory
    self.openFolder = openFolder
    self.selectWorktree = selectWorktree
    self.newSideChat = newSideChat
    self.setGoal = setGoal
    self.togglePlan = togglePlan
    self.isPlanOn = isPlanOn
    self.editQueued = editQueued
    self.sendQueuedNow = sendQueuedNow
    self.removeQueued = removeQueued
    self.moveQueued = moveQueued
    self.recallPrevious = recallPrevious
    self.queueDraft = queueDraft
    self.reconnect = reconnect
    self.dismissCommandNotice = dismissCommandNotice
    self.createAgent = createAgent
    self.importAgentBundle = importAgentBundle
  }
}
