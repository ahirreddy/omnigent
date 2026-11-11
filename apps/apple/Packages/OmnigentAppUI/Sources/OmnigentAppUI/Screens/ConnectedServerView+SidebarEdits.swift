import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The sidebar's edits of a session: a drop, a rename, a move, a pin, an archive, a delete. Each
/// shows at the click; one the server refuses is taken back and shows in the list's alert.
extension ConnectedServerView {
  /// Carries out a sidebar drag: pins into a slot, or files into or out of a project, unpinning
  /// a pin so it shows where it was dropped (the web's `handleDragEnd`). A refused drop shows in
  /// the list's alert, which offers it again.
  func drop(_ session: OmnigentUIComponents.SessionSummary, _ action: SidebarDropAction) {
    let list = connection.sessionList
    Task {
      if await !carryOut(action, on: session.id) {
        list.offerRetry(Self.failureTitle(of: action)) { drop(session, action) }
      }
    }
  }

  /// Makes the writes of a drop, stopping at the first the server refuses.
  /// - Returns: Whether every write was saved.
  private func carryOut(_ action: SidebarDropAction, on sessionID: String) async -> Bool {
    let list = connection.sessionList
    switch action {
    case .move(let project, let unpin):
      guard await list.move(sessionID, to: ProjectSummary(project)) else { return false }
      return unpin ? await list.setPinned(sessionID, false) : true
    case .ungroup(let unpin):
      guard await list.move(sessionID, to: nil) else { return false }
      return unpin ? await list.setPinned(sessionID, false) : true
    case .pin(let target?):
      return await list.movePin(sessionID, slotOf: target)
    case .pin(nil):
      return await list.setPinned(sessionID, true)
    case .unpin:
      return await list.setPinned(sessionID, false)
    case .none:
      return true
    }
  }

  /// The alert's title for a drop the server refused.
  static func failureTitle(of action: SidebarDropAction) -> String {
    switch action {
    case .move, .ungroup, .none: "Could Not Move the Session"
    case .pin: "Could Not Pin the Session"
    case .unpin: "Could Not Unpin the Session"
    }
  }

  /// Deletes or leaves a session; its tabs close once it is gone.
  func removeSession(
    _ sessionID: String, _ operation: @escaping @MainActor (String) async -> Bool
  ) {
    let tabs = session.tabs
    Task {
      if await operation(sessionID) { tabs.removeSessions([sessionID]) }
    }
  }

  /// Renames through the session list. The row shows the title at once; a refusal puts the old
  /// one back and shows in the list's alert, which offers the rename again.
  func rename(_ sessionID: String, to title: String) {
    let list = connection.sessionList
    Task {
      if await !list.rename(sessionID, to: title) {
        list.offerRetry("Could Not Rename the Session") { rename(sessionID, to: title) }
      }
    }
  }

  /// Files a session into `project`, or out of its project; a refusal offers the move again.
  func move(_ sessionID: String, to project: ProjectSummary?) {
    let list = connection.sessionList
    Task {
      if await !list.move(sessionID, to: project) {
        list.offerRetry("Could Not Move the Session") { move(sessionID, to: project) }
      }
    }
  }

  /// Pins or archives through the session list and offers Undo for the change, both at once:
  /// the row and the Undo bar change before the server answers, and a refusal takes both back
  /// and shows in the list's alert, which offers the change again. Archiving also removes the
  /// worktrees of `deletingWorktrees` once the server's Undo grace passes.
  func edit(
    _ change: SidebarUndo.Change, recordUndo: Bool = true, deletingWorktrees: Set<String> = []
  ) {
    let list = connection.sessionList
    let model = sidebarModel
    // The worktree grace counts from the click, so the bar never outlasts the server's.
    let undo = SidebarUndo(change: change, removesWorktrees: !deletingWorktrees.isEmpty)
    if recordUndo { model.undo = undo }
    Task {
      let refused: [String]
      switch change {
      case .pin(let id, let pinned):
        refused = await list.setPinned(id, pinned) ? [] : [id]
      case .archive(let ids, let archived):
        refused = await archive(ids, archived, deletingWorktrees: deletingWorktrees)
      }
      guard !refused.isEmpty else { return }
      if model.undo?.id == undo.id { model.undo = nil }
      list.offerRetry(change.failureTitle(refused: refused.count)) {
        edit(
          change.limited(to: refused), recordUndo: recordUndo,
          deletingWorktrees: deletingWorktrees.intersection(refused))
      }
    }
  }

  /// Archives or restores `ids` as one change of the list. A window showing a session being
  /// archived leaves it at once and comes back if the server refuses; the tabs of an archived
  /// session leave with the server's answer.
  /// - Returns: The sessions the server refused, in the order given.
  private func archive(
    _ ids: [String], _ archived: Bool, deletingWorktrees: Set<String>
  ) async -> [String] {
    let list = connection.sessionList
    let tabs = session.tabs
    let shown = tabs.page
    let left = archived && tabs.showAway(from: Set(ids))
    let landed = tabs.page
    let refused = await list.setArchived(ids, archived, deletingWorktrees: deletingWorktrees)
    if archived {
      // A refused session keeps its tabs, and so does one restored before its archive was sent.
      let gone = ids.filter { !refused.contains($0) && list.session($0)?.isArchived != false }
      tabs.removeSessions(Set(gone))
    }
    if left, tabs.page == landed, let shownID = shown?.sessionID, refused.contains(shownID) {
      tabs.show(shown)
    }
    return ids.filter(refused.contains)
  }
}
