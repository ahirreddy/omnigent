/// A session's nested-agent family (the core's `SessionFamily`): independent sessions grouped
/// under a representative for navigation. Only the viewer's own sessions carry one.
nonisolated public struct SessionFamilyInfo: Hashable, Sendable {
  /// The family's id: its original source session's id, which never changes.
  public var id: String
  /// The representative: the oldest active member, else the oldest kept one.
  public var representativeID: String?
  /// The representative's title.
  public var representativeTitle: String?
  /// The viewer pinned the family.
  public var isPinned: Bool
  /// The family pin's sort value.
  public var pinnedAt: String?

  /// Creates a family.
  /// - Parameters:
  ///   - id: The family id.
  ///   - representativeID: The representative's session id.
  ///   - representativeTitle: The representative's title.
  ///   - isPinned: The viewer pinned the family.
  ///   - pinnedAt: The family pin's sort value.
  public init(
    id: String, representativeID: String? = nil, representativeTitle: String? = nil,
    isPinned: Bool = false, pinnedAt: String? = nil
  ) {
    self.id = id
    self.representativeID = representativeID
    self.representativeTitle = representativeTitle
    self.isPinned = isPinned
    self.pinnedAt = pinnedAt
  }
}

nonisolated extension SessionSummary {
  /// The representative a nested member hangs under; `nil` for a representative or any other
  /// session. A nested member's pin, project and drag are its representative's.
  public var nestedUnder: String? {
    guard let representative = family?.representativeID, representative != id else { return nil }
    return representative
  }

  /// A nested member of a family whose representative is another session.
  public var isNestedFamilyMember: Bool { nestedUnder != nil }

  /// The key a saved order places it by: its family's, so the family moves as one.
  var orderKey: String { family?.id ?? id }

  /// Takes a pin slot when pinned (the core's `session_is_pin_unit`): a session on its own, or
  /// its family's representative.
  var isPinUnit: Bool { family.map { $0.representativeID == id } ?? true }
}
