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
