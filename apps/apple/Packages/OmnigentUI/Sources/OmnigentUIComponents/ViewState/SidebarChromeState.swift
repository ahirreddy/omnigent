import Foundation

/// One server this window can switch to (native multi-server windows).
nonisolated public struct ServerChoice: Hashable, Sendable, Identifiable {
  /// Stable id (the origin).
  public var id: String
  /// Display name.
  public var name: String
  /// The server URL.
  public var url: String
  /// Signed in or reachable.
  public var isConnected: Bool
  /// Provided by the user's organization (a managed server), not a recent one.
  public var isOrganization: Bool

  /// Creates a server choice.
  /// - Parameters:
  ///   - id: Id.
  ///   - name: Name.
  ///   - url: URL.
  ///   - isConnected: Connected.
  ///   - isOrganization: Provided by the organization.
  public init(
    id: String, name: String, url: String, isConnected: Bool = true, isOrganization: Bool = false
  ) {
    self.id = id
    self.name = name
    self.url = url
    self.isConnected = isConnected
    self.isOrganization = isOrganization
  }
}

/// A transient banner offering Undo after pin, unpin or archive (the web's toasts).
nonisolated public struct UndoBanner: Hashable, Sendable, Identifiable {
  /// What the banner undoes.
  public enum Kind: Hashable, Sendable {
    /// "Unpinned session".
    case unpinned
    /// "Pinned session".
    case pinned
    /// "Archived N session(s)", with View archived.
    case archived(count: Int)
  }

  /// Stable id.
  public var id: String
  /// What happened.
  public var kind: Kind
  /// A caveat under the message, such as a worktree that Undo cannot bring back.
  public var note: String?

  /// Creates a banner.
  /// - Parameters:
  ///   - id: Id.
  ///   - kind: What happened.
  ///   - note: A caveat.
  public init(id: String, kind: Kind, note: String? = nil) {
    self.id = id
    self.kind = kind
    self.note = note
  }

  /// The banner text, in the web's words.
  public var message: String {
    switch kind {
    case .unpinned: "Unpinned session"
    case .pinned: "Pinned session"
    case .archived(let count): count == 1 ? "Archived 1 session" : "Archived \(count) sessions"
    }
  }
}
