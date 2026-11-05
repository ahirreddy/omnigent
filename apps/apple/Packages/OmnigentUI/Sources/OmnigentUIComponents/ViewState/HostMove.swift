import Foundation

/// A host the Switch Host and Resume on a Machine sheets list.
nonisolated public struct HostMoveTarget: Hashable, Sendable, Identifiable {
  /// Host id.
  public var id: String
  /// Display name.
  public var name: String
  /// The host's tunnel is up; only online hosts take a runner.
  public var isOnline: Bool

  /// Creates a target.
  /// - Parameters:
  ///   - id: Host id.
  ///   - name: Display name.
  ///   - isOnline: Whether the host is online.
  public init(id: String, name: String, isOnline: Bool) {
    self.id = id
    self.name = name
    self.isOnline = isOnline
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

  /// Creates actions.
  /// - Parameters:
  ///   - loadHosts: Read the hosts.
  ///   - home: Read a host's home.
  ///   - browse: Read a folder.
  ///   - submit: Move or start the session.
  public init(
    loadHosts: @escaping @MainActor () async -> Result<[HostMoveTarget], FolderBrowseError>,
    home: @escaping @MainActor (String) async -> String?,
    browse:
      @escaping @MainActor (String, String?) async -> Result<FolderListing, FolderBrowseError>,
    submit: @escaping @MainActor (HostMoveChoice) async -> HostMoveOutcome
  ) {
    self.loadHosts = loadHosts
    self.home = home
    self.browse = browse
    self.submit = submit
  }
}

/// The sheets' rules, as the web's dialogs apply them.
nonisolated public enum HostMoveRules {
  /// The hosts the sheet offers: online ones, and for Switch Host not the session's own host,
  /// unless a half-finished switch left the session on none (`stranded`).
  /// - Parameters:
  ///   - hosts: The server's hosts.
  ///   - kind: The sheet.
  ///   - stranded: A switch released the old host and failed to start on the new one.
  /// - Returns: The targets, in the server's order.
  public static func targets(_ hosts: [HostMoveTarget], kind: HostMoveKind, stranded: Bool)
    -> [HostMoveTarget]
  {
    hosts.filter { host in
      guard host.isOnline else { return false }
      if case .switchHost(let current) = kind, !stranded { return host.id != current }
      return true
    }
  }

  /// The host selected on open: for Resume the session's own host when it is online, else the
  /// first target.
  public static func defaultHost(_ targets: [HostMoveTarget], kind: HostMoveKind) -> String? {
    if case .resume(let preferred?, _) = kind, targets.contains(where: { $0.id == preferred }) {
      return preferred
    }
    return targets.first?.id
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
