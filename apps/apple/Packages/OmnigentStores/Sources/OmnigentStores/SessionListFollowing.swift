public import OmnigentCoreFFI

/// Told after each change to a ``SessionListStore``'s rows, attention, read marks or drafts.
public protocol SessionListFollower: AnyObject {
  /// The list changed; its values are already the new ones.
  /// - Parameter list: The list.
  func sessionListChanged(_ list: SessionListStore)
}

/// A follower the list does not keep alive.
struct WeakSessionListFollower {
  weak var follower: (any SessionListFollower)?
}

/// A ``SessionListStore``'s rows and marks at one moment.
public struct SessionListContents: Equatable, Sendable {
  /// The sessions matching the search and filter, in display order.
  public var visible: [SessionSummary]
  /// Each known session's attention, by id.
  public var attention: [String: SessionAttention]
  /// Totals across every known session.
  public var totals: AttentionTotals
  /// Sessions with activity the user has not seen.
  public var unreadIDs: Set<String>
  /// Sessions whose composer holds an unsent draft.
  public var draftSessionIDs: Set<String>
}

extension SessionListStore {
  /// Tells `follower` after each change, for a reader that decides for itself what a change
  /// means to it. The list holds it weakly.
  /// - Parameter follower: Who to tell.
  public func follow(_ follower: any SessionListFollower) {
    followers.removeAll { $0.follower == nil || $0.follower === follower }
    followers.append(WeakSessionListFollower(follower: follower))
  }

  func tellFollowers() {
    for entry in followers { entry.follower?.sessionListChanged(self) }
  }
}
