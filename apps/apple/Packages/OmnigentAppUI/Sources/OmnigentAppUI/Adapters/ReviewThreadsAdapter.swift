import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// Places the open PR's review threads and local comments on its stacked diff, as the web's
/// `reviewThreadAnnotations` and `PullRequestFileSection` do: a thread or comment on a line the
/// diff shows sits under that line; one that is outdated, about the whole file, read at another
/// revision, or outside the diff's hunks sits under its file's header. Earlier (outdated) ones
/// show only once the file's "Show earlier comments" is on.
enum ReviewThreadsAdapter {
  /// What may be written on the diff.
  struct Permissions {
    /// The provider takes new threads at the revision shown.
    var canCreate: Bool
    /// The server keeps local comments for the agent.
    var canCommentLocally: Bool
    /// The viewer may change the session.
    var canEdit: Bool
  }

  /// The diff's annotations for `files`: threads, local comments, the new thread, and choosing
  /// lines.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - files: The diff's files.
  ///   - canEdit: The caller can change the session.
  /// - Returns: The annotations; none when the host has no review threads.
  static func annotations(
    _ panel: SessionPanelStore, files: [OmnigentWorkspaceUI.FileDiff], canEdit: Bool
  ) -> StackedDiffAnnotations {
    annotations(
      panel, files: files.map(StackedDiffFile.init(diff:)),
      permissions: permissions(panel, canEdit: canEdit))
  }

  /// Who may write what on the open PR's diff, as the web's `threadContext.canCreate` and
  /// `canCommentLocally`.
  static func permissions(_ panel: SessionPanelStore, canEdit: Bool) -> Permissions {
    let info = panel.detail.value
    let pullRequest = info?.pullRequest
    let patch = panel.files.value
    let open = pullRequest.map { $0.status == .open || $0.status == .draft } ?? false
    let atPatch =
      pullRequest?.headSha != nil && pullRequest?.baseSha != nil
      && patch?.headSha == pullRequest?.headSha && patch?.baseSha == pullRequest?.baseSha
    let canCreate =
      canEdit && info?.capabilities.reviewThreadCreation == true && open && atPatch
      && panel.reviewThreads.value != nil
    let revision = panel.reviewRevision
    let local =
      canEdit && panel.offersLocalComments && revision.head != nil && revision.base != nil
    return Permissions(canCreate: canCreate, canCommentLocally: local, canEdit: canEdit)
  }

  /// The annotations for `files` with `permissions`.
  static func annotations(
    _ panel: SessionPanelStore, files: [StackedDiffFile], permissions: Permissions
  ) -> StackedDiffAnnotations {
    var annotations = StackedDiffAnnotations()
    guard let info = panel.detail.value, info.pullRequest != nil else { return annotations }
    let context = placement(panel, info: info, permissions: permissions)
    for file in files { place(file, context, into: &annotations) }
    annotations.selection = panel.newReviewThread.map(selection)
    if permissions.canCreate || permissions.canCommentLocally {
      let forced: ReviewCommentDestination? = permissions.canCreate ? nil : .agent
      annotations.select = { lines in
        panel.selectReviewLines(
          ReviewThreadDraft(
            path: lines.path, side: lines.side == .old ? .left : .right, start: lines.start,
            end: lines.end, hunk: lines.hunk),
          destination: forced)
      }
    }
    return annotations
  }

  /// What placing one file's threads and comments needs.
  struct Placement {
    let threads: [ReviewThread]
    let localComments: [LocalReviewComment]
    /// The threads were read at the revision the diff shows.
    let matching: Bool
    let draft: ReviewThreadDraft?
    let newThread: PullRequestNewThreadState?
    let replies: [String: String]
    let permissions: Permissions
    let caps: PullRequestCapabilities
    let earlierShown: Set<String>
    let actions: PullRequestReviewActions
    let localActions: PullRequestLocalCommentActions
    let isEarlier: @MainActor (LocalReviewComment) -> Bool
    let viewer: String?
  }

  static func placement(
    _ panel: SessionPanelStore, info: PullRequestInfo, permissions: Permissions
  ) -> Placement {
    let pullRequest = info.pullRequest
    let page = panel.reviewThreads.value
    return Placement(
      threads: info.capabilities.reviewThreads ? page?.threads ?? [] : [],
      localComments: panel.openLocalComments,
      matching: page.map {
        $0.headSha == pullRequest?.headSha && $0.baseSha == pullRequest?.baseSha
      }
        ?? false,
      draft: panel.newReviewThread,
      newThread: panel.newReviewThread.map { newThreadState($0, panel, permissions) },
      replies: panel.reviewReplies, permissions: permissions, caps: info.capabilities,
      earlierShown: panel.changesView.shownEarlierComments,
      actions: actions(panel, permissions: permissions, caps: info.capabilities),
      localActions: localActions(panel, canEdit: permissions.canEdit),
      isEarlier: { panel.isEarlier($0) }, viewer: panel.viewedScope?()?.user)
  }

  /// Puts `file`'s threads and comments under their lines, or under its header.
  private static func place(
    _ file: StackedDiffFile, _ context: Placement, into annotations: inout StackedDiffAnnotations
  ) {
    let paths = Set([file.path, file.previousPath, file.diff?.oldPath].compactMap(\.self))
    let earlierShown = context.earlierShown.contains(file.path)
    var placed: [DiffLineAnchor: [PullRequestReviewThreadState]] = [:]
    var placedLocal: [DiffLineAnchor: [PullRequestLocalCommentState]] = [:]
    var unplaced: [PullRequestReviewThreadState] = []
    var unplacedLocal: [PullRequestLocalCommentState] = []
    for thread in context.threads where paths.contains(thread.path) {
      guard !thread.outdated || earlierShown else { continue }
      var state = threadState(
        thread, reply: context.replies[thread.id], canEdit: context.permissions.canEdit,
        caps: context.caps)
      state.suggestionSource = suggestionSource(thread, file: context.matching ? file.diff : nil)
      if context.matching, let diff = file.diff,
        let anchor = anchor(thread, in: diff, path: file.path)
      {
        placed[anchor, default: []].append(state)
      } else {
        unplaced.append(withContext(state, thread))
      }
    }
    for comment in context.localComments where comment.path == file.path {
      let earlier = context.isEarlier(comment)
      guard !earlier || earlierShown else { continue }
      let state = localState(comment, earlier: earlier, context: context)
      if !earlier, let diff = file.diff, let anchor = anchor(comment, in: diff, path: file.path) {
        placedLocal[anchor, default: []].append(state)
      } else {
        unplacedLocal.append(state)
      }
    }
    let draft = context.draft.flatMap { $0.path == file.path ? $0 : nil }
    let newAnchor = draft.map(newThreadAnchor)
    let anchors = Set(placed.keys).union(placedLocal.keys).union(newAnchor.map { [$0] } ?? [])
    for anchor in anchors {
      annotations.lines[anchor] = AnyView(
        PullRequestReviewThreadsView(
          threads: placed[anchor] ?? [],
          newThread: anchor == newAnchor ? context.newThread : nil,
          localComments: placedLocal[anchor] ?? [], actions: context.actions,
          localActions: context.localActions))
    }
    if !unplaced.isEmpty || !unplacedLocal.isEmpty {
      annotations.files[file.path] = AnyView(
        PullRequestReviewThreadsView(
          threads: unplaced, localComments: unplacedLocal, actions: context.actions,
          localActions: context.localActions))
    }
  }

  private static func newThreadAnchor(_ draft: ReviewThreadDraft) -> DiffLineAnchor {
    DiffLineAnchor(path: draft.path, side: draft.side == .left ? .old : .new, line: draft.end)
  }

  private static func newThreadState(
    _ draft: ReviewThreadDraft, _ panel: SessionPanelStore, _ permissions: Permissions
  ) -> PullRequestNewThreadState {
    var state = PullRequestNewThreadState(
      lineLabel: PullRequestReviewThreadState.lineLabel(
        old: draft.side == .left, start: draft.start, end: draft.end),
      body: draft.body,
      problem: draft.body.isEmpty ? nil : reviewCommentProblem(body: draft.body))
    state.toAgent = draft.destination == .agent
    state.offersProvider = permissions.canCreate
    state.offersAgent = permissions.canCommentLocally
    state.isStale = panel.newReviewThreadIsStale
    return state
  }

  private static func selection(_ draft: ReviewThreadDraft) -> DiffLineSelection {
    DiffLineSelection(
      path: draft.path, side: draft.side == .left ? .old : .new, start: draft.start,
      end: draft.end, hunk: draft.hunk)
  }

  private static func actions(
    _ panel: SessionPanelStore, permissions: Permissions, caps: PullRequestCapabilities
  ) -> PullRequestReviewActions {
    var actions = PullRequestReviewActions()
    actions.isBusy = panel.pendingEdit != nil
    actions.account = panel.detail.value?.selectedAccount
    actions.providerName = panel.detail.value?.providerName ?? "GitHub"
    actions.loadOlder = { id in Task { await panel.loadOlderReviewComments(id) } }
    guard permissions.canEdit else { return actions }
    if caps.reviewThreadReplies {
      actions.setReply = { id, text in panel.setReviewReply(text, for: id) }
      actions.reply = { id in Task { await panel.replyToReviewThread(id) } }
    }
    if permissions.canCreate || permissions.canCommentLocally || panel.newReviewThread != nil {
      actions.setNewBody = { panel.setNewReviewThreadBody($0) }
      actions.postNew = { Task { await panel.startReviewThread() } }
      actions.cancelNew = { panel.cancelNewReviewThread() }
    }
    if permissions.canCommentLocally {
      actions.setNewToAgent = { panel.setNewReviewThreadDestination($0 ? .agent : .github) }
    }
    return actions
  }

  private static func localActions(_ panel: SessionPanelStore, canEdit: Bool)
    -> PullRequestLocalCommentActions
  {
    var actions = PullRequestLocalCommentActions()
    actions.isBusy = panel.pendingEdit != nil
    guard canEdit else { return actions }
    actions.edit = { id, body, done in Task { done(await panel.editLocalComment(id, body: body)) } }
    actions.delete = { id in Task { await panel.deleteLocalComment(id) } }
    return actions
  }
}
