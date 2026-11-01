// Edit approvals list the files they change, as the core reads them from the gated tool call.

/// One file an edit approval would change, with line counts when known.
nonisolated public struct DecisionFileChange: Hashable, Sendable, Identifiable {
  /// What happens to a file.
  public enum Kind: Hashable, Sendable {
    /// Created.
    case create
    /// Parts of it change.
    case modify
    /// Deleted.
    case delete
    /// Written whole: created, or replaced without its old content being known.
    case write
  }

  /// The path as the agent reported it.
  public var path: String
  /// What happens to it, when the request says.
  public var kind: Kind?
  /// Lines added, when known.
  public var added: Int?
  /// Lines removed, when known.
  public var removed: Int?

  /// The path identifies the file.
  public var id: String { path }

  /// Creates a file change.
  /// - Parameters:
  ///   - path: Path.
  ///   - added: Lines added.
  ///   - removed: Lines removed.
  ///   - kind: What happens to it.
  public init(path: String, added: Int? = nil, removed: Int? = nil, kind: Kind? = nil) {
    self.path = path
    self.kind = kind
    self.added = added
    self.removed = removed
  }
}
