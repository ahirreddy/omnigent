import Foundation

/// A host the Switch Host and Resume on a Machine sheets list, or a new sandbox Switch Host can
/// move the session into.
nonisolated public struct HostMoveTarget: Hashable, Sendable, Identifiable {
  /// Host id; for a sandbox row, unique among the rows.
  public var id: String
  /// Display name: the host's, or "Modal Sandbox".
  public var name: String
  /// The host's tunnel is up; only online hosts take a runner. A sandbox row is always offered.
  public var isOnline: Bool
  /// The provider of a new sandbox; `nil` for a host.
  public var sandboxProvider: String?

  /// Creates a target.
  /// - Parameters:
  ///   - id: Host id.
  ///   - name: Display name.
  ///   - isOnline: Whether the host is online.
  ///   - sandboxProvider: The provider, for a new sandbox.
  public init(id: String, name: String, isOnline: Bool, sandboxProvider: String? = nil) {
    self.id = id
    self.name = name
    self.isOnline = isOnline
    self.sandboxProvider = sandboxProvider
  }

  /// A new sandbox of `provider`, as the web's `__sandbox__:<provider>` row.
  /// - Parameters:
  ///   - provider: The provider.
  ///   - name: "Modal Sandbox".
  /// - Returns: The row.
  public static func sandbox(_ provider: String, name: String) -> Self {
    Self(id: "__sandbox__:\(provider)", name: name, isOnline: true, sandboxProvider: provider)
  }
}

/// A new sandbox chosen in Switch Host: its provider and the repository it clones.
nonisolated public struct HostMoveSandbox: Hashable, Sendable {
  /// The provider.
  public var provider: String
  /// The repository URL; blank starts an empty sandbox.
  public var repository: String
  /// Its branch; blank for the default branch.
  public var branch: String

  /// Creates a choice.
  /// - Parameters:
  ///   - provider: The provider.
  ///   - repository: The repository URL.
  ///   - branch: The branch.
  public init(provider: String, repository: String, branch: String) {
    self.provider = provider
    self.repository = repository
    self.branch = branch
  }
}

/// Why a sandbox's repository and branch can't be sent, under the field it belongs to.
nonisolated public struct HostMoveRepoProblem: Hashable, Sendable {
  /// It belongs under Branch, else under Repository.
  public var isBranch: Bool
  /// What to show.
  public var message: String

  /// Creates a problem.
  /// - Parameters:
  ///   - isBranch: It belongs under Branch.
  ///   - message: What to show.
  public init(isBranch: Bool, message: String) {
    self.isBranch = isBranch
    self.message = message
  }
}

/// Which sheet: moving a bound session to another host (the web's `SwitchHostDialog`), or
/// starting a session bound to no host (`ResumeWithDirectoryDialog`).
nonisolated public enum HostMoveKind: Hashable, Sendable {
  /// Switch Host, away from `currentHostID`.
  case switchHost(currentHostID: String?)
  /// Resume on a Machine, preferring the session's recorded host and directory.
  case resume(preferredHostID: String?, workspace: String?)
}

/// What the user chose in the sheet.
nonisolated public struct HostMoveChoice: Hashable, Sendable {
  /// The host.
  public var hostID: String
  /// The absolute directory.
  public var workspace: String
  /// A new worktree branch (Resume only); blank starts in the directory.
  public var branch = ""
  /// The new worktree's base branch; blank takes the current one.
  public var baseBranch = ""
  /// A new sandbox to move into instead of a host (Switch Host only).
  public var sandbox: HostMoveSandbox?

  /// Creates a choice.
  /// - Parameters:
  ///   - hostID: The host.
  ///   - workspace: The absolute directory.
  public init(hostID: String, workspace: String) {
    self.hostID = hostID
    self.workspace = workspace
  }
}

/// How a move went.
nonisolated public enum HostMoveOutcome: Hashable, Sendable {
  /// The runner is starting on the chosen host; the sheet closes.
  case moved
  /// Nothing moved; the message says why.
  case failed(String)
  /// The session left its old host but did not start on the new one, so it runs nowhere.
  case stranded(String)
  /// The session left its old host and the sandbox request failed, so whether it moved is not
  /// known.
  case unconfirmed(String)
}

/// What the sheets read and do. Each runs on the main actor.
public struct HostMoveActions {
  /// The server's hosts.
  public var loadHosts: @MainActor () async -> Result<[HostMoveTarget], FolderBrowseError>
  /// A host's home directory, the default when nothing better is known.
  public var home: @MainActor (_ hostID: String) async -> String?
  /// Reads a folder on a host for the folder browser (`nil` path: its home).
  public var browse:
    @MainActor (_ hostID: String, _ path: String?) async -> Result<
      FolderListing, FolderBrowseError
    >
  /// Moves or starts the session.
  public var submit: @MainActor (HostMoveChoice) async -> HostMoveOutcome
  /// Why a sandbox's repository and branch can't be sent; `nil` when they can.
  public var sandboxProblem:
    @MainActor (_ repository: String, _ branch: String) -> HostMoveRepoProblem?

  /// Creates actions.
  /// - Parameters:
  ///   - loadHosts: Read the hosts.
  ///   - home: Read a host's home.
  ///   - browse: Read a folder.
  ///   - submit: Move or start the session.
  ///   - sandboxProblem: Check a sandbox's repository and branch.
  public init(
    loadHosts: @escaping @MainActor () async -> Result<[HostMoveTarget], FolderBrowseError>,
    home: @escaping @MainActor (String) async -> String?,
    browse:
      @escaping @MainActor (String, String?) async -> Result<FolderListing, FolderBrowseError>,
    submit: @escaping @MainActor (HostMoveChoice) async -> HostMoveOutcome,
    sandboxProblem: @escaping @MainActor (String, String) -> HostMoveRepoProblem? = { _, _ in nil }
  ) {
    self.loadHosts = loadHosts
    self.home = home
    self.browse = browse
    self.submit = submit
    self.sandboxProblem = sandboxProblem
  }
}

/// The sheets' rules, as the web's dialogs apply them.
nonisolated public enum HostMoveRules {
  /// The hosts the sheet offers: online ones, and for Switch Host not the session's own host,
  /// unless a half-finished switch left the session on none (`stranded`). Switch Host's new
  /// sandboxes come first, as on the web; Resume offers none.
  /// - Parameters:
  ///   - hosts: The server's hosts and Switch Host's sandbox rows.
  ///   - kind: The sheet.
  ///   - stranded: A switch released the old host and failed to start on the new one.
  /// - Returns: The targets: sandboxes, then hosts in the server's order.
  public static func targets(_ hosts: [HostMoveTarget], kind: HostMoveKind, stranded: Bool)
    -> [HostMoveTarget]
  {
    let offered = hosts.filter { host in
      guard host.isOnline else { return false }
      guard case .switchHost(let current) = kind else { return host.sandboxProvider == nil }
      return stranded || host.id != current
    }
    return offered.filter { $0.sandboxProvider != nil }
      + offered.filter { $0.sandboxProvider == nil }
  }

  /// The host selected on open: for Resume the session's own host when it is online, else the
  /// first host; a sandbox only when no host is online, as the web never defaults to one.
  public static func defaultHost(_ targets: [HostMoveTarget], kind: HostMoveKind) -> String? {
    if case .resume(let preferred?, _) = kind, targets.contains(where: { $0.id == preferred }) {
      return preferred
    }
    return (targets.first { $0.sandboxProvider == nil } ?? targets.first)?.id
  }

  /// What the sheet says it does.
  /// - Parameters:
  ///   - kind: The sheet.
  ///   - offersSandbox: Switch Host lists a new sandbox.
  /// - Returns: The description.
  public static func description(_ kind: HostMoveKind, offersSandbox: Bool) -> String {
    guard case .switchHost = kind else {
      return "This session isn\u{2019}t running on any machine. Pick one of your machines and a "
        + "directory to continue the conversation against your files."
    }
    return offersSandbox
      ? "Move this session to another connected machine or a new sandbox."
      : "Move this session to another connected machine."
  }

  /// What the sheet says when nothing can take the session.
  /// - Parameter kind: The sheet.
  /// - Returns: The note.
  public static func noTargets(_ kind: HostMoveKind) -> String {
    guard case .switchHost = kind else {
      return "None of your machines are online. Start one with `omnigent host` from your "
        + "terminal, then reopen this sheet."
    }
    return "No other hosts are online. Connect one with `omnigent host` and try again."
  }

  /// A typed directory as an absolute path: `/…` without trailing slashes, `~` and `~/…`
  /// against the host's `home`; `nil` for anything else or before the home is known (the
  /// server never expands `~`).
  public static func resolvedWorkspace(_ typed: String, home: String?) -> String? {
    let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") { return stripped(trimmed) }
    guard let home, trimmed == "~" || trimmed.hasPrefix("~/") else { return nil }
    let rest = trimmed.dropFirst(trimmed == "~" ? 1 : 2)
    let base = stripped(home)
    if rest.isEmpty { return base }
    return stripped(base == "/" ? "/\(rest)" : "\(base)/\(rest)")
  }

  private static func stripped(_ path: String) -> String {
    var path = path
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }
}
