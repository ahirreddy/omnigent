import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// Places the open PR's review threads on its stacked diff, as the web's
/// `reviewThreadAnnotations` does: a thread on a line the diff shows sits under that line; one
/// that is outdated, about the whole file, read at another revision, or outside the diff's
/// hunks sits under its file's header with the code it was written on.
enum ReviewThreadsAdapter {
  /// The diff's annotations: threads, the new thread being written, and choosing lines.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - files: The diff's files.
  ///   - canEdit: The caller can change the session.
  /// - Returns: The annotations; none when the host has no review threads.
  static func annotations(
    _ panel: SessionPanelStore, files: [OmnigentWorkspaceUI.FileDiff], canEdit: Bool
  )
    -> StackedDiffAnnotations
  {
    var annotations = StackedDiffAnnotations()
    guard let info = panel.detail.value, let pullRequest = info.pullRequest,
      info.capabilities.reviewThreads
    else { return annotations }
    let page = panel.reviewThreads.value
    let context = Placement(
      threads: page?.threads ?? [],
      matching: page.map { $0.headSha == pullRequest.headSha && $0.baseSha == pullRequest.baseSha }
        ?? false,
      draft: panel.newReviewThread, replies: panel.reviewReplies, canEdit: canEdit,
      caps: info.capabilities, actions: actions(panel, canEdit: canEdit, caps: info.capabilities))
    for file in files { place(file, context, into: &annotations) }
    annotations.selection = panel.newReviewThread.map(selection)
    let creates = canEdit && info.capabilities.reviewThreadCreation
    if creates, pullRequest.headSha != nil, pullRequest.baseSha != nil {
      annotations.select = { lines in
        panel.selectReviewLines(
          ReviewThreadDraft(
            path: lines.path, side: lines.side == .old ? .left : .right, start: lines.start,
            end: lines.end, hunk: lines.hunk))
      }
    }
    return annotations
  }

  /// What placing one file's threads needs.
  private struct Placement {
    let threads: [ReviewThread]
    /// The threads were read at the revision the diff shows.
    let matching: Bool
    let draft: ReviewThreadDraft?
    let replies: [String: String]
    let canEdit: Bool
    let caps: PullRequestCapabilities
    let actions: PullRequestReviewActions
  }

  /// Puts `file`'s threads under their lines, or under its header.
  private static func place(
    _ file: OmnigentWorkspaceUI.FileDiff, _ context: Placement,
    into annotations: inout StackedDiffAnnotations
  ) {
    var placed: [DiffLineAnchor: [PullRequestReviewThreadState]] = [:]
    var unplaced: [PullRequestReviewThreadState] = []
    for thread in context.threads where thread.path == file.newPath || thread.path == file.oldPath {
      let state = threadState(
        thread, reply: context.replies[thread.id], canEdit: context.canEdit, caps: context.caps)
      if context.matching, let anchor = anchor(thread, in: file) {
        placed[anchor, default: []].append(state)
      } else {
        unplaced.append(withContext(state, thread))
      }
    }
    let draft = context.draft.flatMap { $0.path == file.path ? $0 : nil }
    let newAnchor = draft.map(newThreadAnchor)
    for anchor in Set(placed.keys).union(newAnchor.map { [$0] } ?? []) {
      annotations.lines[anchor] = AnyView(
        PullRequestReviewThreadsView(
          threads: placed[anchor] ?? [],
          newThread: anchor == newAnchor ? draft.map(newThreadState) : nil,
          actions: context.actions))
    }
    if !unplaced.isEmpty {
      annotations.files[file.path] = AnyView(
        PullRequestReviewThreadsView(threads: unplaced, actions: context.actions))
    }
  }

  /// Where a thread sits, when the diff shows its line on its side.
  static func anchor(_ thread: ReviewThread, in file: OmnigentWorkspaceUI.FileDiff)
    -> DiffLineAnchor?
  {
    guard !thread.outdated, !thread.onFile, let line = thread.line, let side = thread.side else {
      return nil
    }
    let old = side == .left
    let shown = file.hunks.contains { hunk in
      hunk.lines.contains { row in
        old
          ? row.kind != .added && row.oldNumber == line
          : row.kind != .removed && row.newNumber == line
      }
    }
    return shown ? DiffLineAnchor(path: file.path, side: old ? .old : .new, line: line) : nil
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

  private static func withContext(
    _ state: PullRequestReviewThreadState, _ thread: ReviewThread
  ) -> PullRequestReviewThreadState {
    var state = state
    state.originalContext = thread.diffHunk.isEmpty ? nil : thread.diffHunk
    return state
  }

  private static func newThreadAnchor(_ draft: ReviewThreadDraft) -> DiffLineAnchor {
    DiffLineAnchor(path: draft.path, side: draft.side == .left ? .old : .new, line: draft.end)
  }

  private static func newThreadState(_ draft: ReviewThreadDraft) -> PullRequestNewThreadState {
    PullRequestNewThreadState(
      lineLabel: PullRequestReviewThreadState.lineLabel(
        old: draft.side == .left, start: draft.start, end: draft.end),
      body: draft.body,
      problem: draft.body.isEmpty ? nil : reviewCommentProblem(body: draft.body))
  }

  private static func selection(_ draft: ReviewThreadDraft) -> DiffLineSelection {
    DiffLineSelection(
      path: draft.path, side: draft.side == .left ? .old : .new, start: draft.start,
      end: draft.end, hunk: draft.hunk)
  }

  private static func actions(
    _ panel: SessionPanelStore, canEdit: Bool, caps: PullRequestCapabilities
  ) -> PullRequestReviewActions {
    var actions = PullRequestReviewActions()
    actions.isBusy = panel.pendingEdit != nil
    actions.loadOlder = { id in Task { await panel.loadOlderReviewComments(id) } }
    guard canEdit else { return actions }
    if caps.reviewThreadReplies {
      actions.setReply = { id, text in panel.setReviewReply(text, for: id) }
      actions.reply = { id in Task { await panel.replyToReviewThread(id) } }
    }
    if caps.reviewThreadCreation {
      actions.setNewBody = { panel.setNewReviewThreadBody($0) }
      actions.postNew = { Task { await panel.startReviewThread() } }
      actions.cancelNew = { panel.cancelNewReviewThread() }
    }
    return actions
  }
}
