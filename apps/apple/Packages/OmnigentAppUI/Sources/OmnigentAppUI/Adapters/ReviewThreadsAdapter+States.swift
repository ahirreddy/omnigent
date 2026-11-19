import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI

/// Where threads and local comments sit on a file's diff, and their cards' states.
extension ReviewThreadsAdapter {
  /// Where a thread sits, when the diff shows its line on its side.
  static func anchor(
    _ thread: ReviewThread, in file: OmnigentWorkspaceUI.FileDiff, path: String? = nil
  ) -> DiffLineAnchor? {
    guard !thread.outdated, !thread.onFile, let line = thread.line, let side = thread.side else {
      return nil
    }
    return shown(line, old: side == .left, in: file, path: path ?? file.path)
  }

  /// Where a local comment sits, when the diff shows its whole range on its side.
  static func anchor(
    _ comment: LocalReviewComment, in file: OmnigentWorkspaceUI.FileDiff, path: String
  ) -> DiffLineAnchor? {
    let old = comment.anchor.side == .left
    let start = comment.anchor.startLine ?? comment.anchor.line
    guard
      let hunk = file.hunks.first(where: { hunk in shows(hunk, comment.anchor.line, old: old) }),
      shows(hunk, start, old: old)
    else { return nil }
    return DiffLineAnchor(path: path, side: old ? .old : .new, line: comment.anchor.line)
  }

  private static func shown(
    _ line: UInt64, old: Bool, in file: OmnigentWorkspaceUI.FileDiff, path: String
  ) -> DiffLineAnchor? {
    let isShown = file.hunks.contains { shows($0, line, old: old) }
    return isShown ? DiffLineAnchor(path: path, side: old ? .old : .new, line: line) : nil
  }

  private static func shows(_ hunk: OmnigentWorkspaceUI.DiffHunk, _ line: UInt64, old: Bool)
    -> Bool
  {
    hunk.lines.contains { row in
      old
        ? row.kind != .added && row.oldNumber == line
        : row.kind != .removed && row.newNumber == line
    }
  }

  static func threadState(
    _ thread: ReviewThread, reply: String?, canEdit: Bool, caps: PullRequestCapabilities
  ) -> PullRequestReviewThreadState {
    let line = thread.outdated ? thread.originalLine : thread.line
    let start = thread.outdated ? thread.originalStartLine : thread.startLine
    var state = PullRequestReviewThreadState(
      id: thread.id,
      lineLabel: PullRequestReviewThreadState.lineLabel(
        old: thread.side == .left, start: start, end: thread.onFile ? nil : line),
      comments: thread.comments.comments.map { comment in
        PullRequestReviewCommentRow(
          id: comment.id, author: comment.author ?? "unknown",
          date: comment.createdAt.flatMap { try? Date($0, strategy: .iso8601) },
          body: comment.body, url: comment.url.flatMap(URL.init(string:)),
          hidden: comment.minimized)
      })
    state.outdated = thread.outdated
    state.resolved = thread.resolved
    state.hasOlderComments = thread.comments.hasMore
    state.warning = thread.comments.warning
    state.canReply = canEdit && caps.reviewThreadReplies && thread.canReply
    state.reply = reply ?? ""
    return state
  }

  static func localState(
    _ comment: LocalReviewComment, earlier: Bool, context: Placement
  ) -> PullRequestLocalCommentState {
    // Anyone who may edit the session edits a comment without an author (single-user mode).
    let own =
      context.permissions.canEdit && (comment.author == nil || comment.author == context.viewer)
    return PullRequestLocalCommentState(
      id: comment.id,
      lineLabel: PullRequestLocalCommentState.lineLabel(
        old: comment.anchor.side == .left, start: comment.anchor.startLine,
        end: comment.anchor.line),
      earlier: earlier, addressed: comment.status == "addressed", body: comment.body,
      canEdit: own)
  }

  static func withContext(
    _ state: PullRequestReviewThreadState, _ thread: ReviewThread
  ) -> PullRequestReviewThreadState {
    var state = state
    state.originalContext = thread.diffHunk.isEmpty ? nil : thread.diffHunk
    return state
  }
}
