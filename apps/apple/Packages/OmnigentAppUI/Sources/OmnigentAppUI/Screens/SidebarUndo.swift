import Foundation
import OmnigentUIComponents

/// A sidebar change the user can undo from the undo bar.
struct SidebarUndo: Identifiable {
  enum Change {
    case pin(String, Bool)
    case archive([String], Bool)
  }

  /// How long the server waits before tearing down an archived session (its
  /// `_ARCHIVE_STOP_UNDO_GRACE_S` is 8 s), with margin for the unarchive request, as the web's
  /// Undo pill keeps.
  static let worktreeGrace: TimeInterval = 5

  let id: String
  let change: Change
  /// The archive also removes worktrees once the grace passes.
  var removesWorktrees: Bool
  var createdAt: Date

  init(change: Change, removesWorktrees: Bool = false, createdAt: Date = .now) {
    id = UUID().uuidString
    self.change = change
    self.removesWorktrees = removesWorktrees
    self.createdAt = createdAt
  }

  var banner: UndoBanner? {
    switch change {
    case .pin(_, let pinned): UndoBanner(id: id, kind: pinned ? .pinned : .unpinned)
    case .archive(let ids, true):
      UndoBanner(
        id: id, kind: .archived(count: ids.count),
        note: removesWorktrees
          ? "Worktrees are removed in a few seconds; Undo after that restores only the session."
          : nil)
    case .archive(_, false): nil
    }
  }

  /// What to tell the user when Undo comes after the server removed the worktrees: the
  /// session is back, its branch is kept, its worktree is not.
  func lostWorktreeWarning(now: Date) -> String? {
    guard removesWorktrees, now.timeIntervalSince(createdAt) >= Self.worktreeGrace else {
      return nil
    }
    return "Restored, but its worktree was already removed. The branch is kept: start a new "
      + "session in that branch's worktree to keep working on it."
  }

  var inverse: Change {
    switch change {
    case .pin(let id, let pinned): .pin(id, !pinned)
    case .archive(let ids, let archived): .archive(ids, !archived)
    }
  }
}

extension SidebarUndo.Change {
  /// The alert's title when the server refused the change for `refused` of its sessions.
  func failureTitle(refused: Int) -> String {
    let sessions = refused == 1 ? "the Session" : "\(refused) Sessions"
    return switch self {
    case .pin(_, true): "Could Not Pin the Session"
    case .pin(_, false): "Could Not Unpin the Session"
    case .archive(_, true): "Could Not Archive \(sessions)"
    case .archive(_, false): "Could Not Unarchive \(sessions)"
    }
  }

  /// The same change for only `sessionIDs`: what is left to retry after a partial refusal.
  func limited(to sessionIDs: [String]) -> Self {
    switch self {
    case .pin: self
    case .archive(_, let archived): .archive(sessionIDs, archived)
    }
  }
}
