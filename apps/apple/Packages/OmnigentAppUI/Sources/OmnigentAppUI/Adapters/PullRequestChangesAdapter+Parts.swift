import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// The Changes tab's notices, find bar, commits and the comments no file shows.
extension PullRequestChangesAdapter {
  static func notices(_ inputs: Inputs, into state: inout PullRequestChangesState) {
    let panel = inputs.panel
    let files = inputs.files
    let view = panel.changesView
    let reviewing = panel.isReviewing
    if reviewing, panel.detail.value?.capabilities.reviewThreads == true {
      let page = panel.reviewThreads.value
      state.hasMoreThreads = page?.hasMore == true
      state.reviewNotice =
        panel.reviewThreads.error.map {
          "Couldn\u{2019}t load review conversations: \($0.message)"
        } ?? page?.warning
    }
    if panel.changesMode != .commits, !panel.showsPatchView, let list = panel.changes.value,
      list.hasMore || list.warning != nil
    {
      state.listingNotice = list.warning ?? "The changed-file list is incomplete."
    }
    if view.find.isOpen, inputs.listing.patchReady, inputs.listing.error == nil {
      let patchCount = files.count { $0.diff != nil }
      let withoutText = files.count - patchCount
      let truncated = !panel.showsPatchView && panel.changes.value?.hasMore == true
      let total =
        panel.showsPatchView
        ? files.count : panel.changes.value?.totalCount.map { Int($0) } ?? files.count
      if truncated || withoutText > 0 {
        state.coverageNote =
          "Search covers the fetched patch: \(patchCount) of \(total) files"
          + (withoutText > 0 ? ", \(withoutText) without text" : "")
      }
    }
    let changedListed = files.contains { inputs.viewed.changed.contains($0.path) }
    state.showsResetNotice =
      reviewing && changedListed && view.dismissedResetHead != panel.renderedHead
  }

  static func findState(
    _ view: PullRequestChangesTabState, results: (visible: DiffFindResult, hidden: DiffFindResult),
    active: Int?
  ) -> PullRequestFindState {
    var find = PullRequestFindState()
    find.isOpen = view.find.isOpen
    find.query = view.find.query
    find.matchCase = view.find.matchCase
    find.regex = view.find.regex
    find.total = results.visible.matches.count
    find.status = DiffFind.status(
      query: view.find.query, result: results.visible, position: active.map { $0 + 1 } ?? 0)
    let hidden = results.hidden.matches.count
    if hidden > 0 {
      find.hidden = "+\(hidden)\(results.hidden.truncated ? "+" : "") in hidden files"
    }
    return find
  }

  static func commitRows(_ commits: [PullRequestCommit], numberPrefix: String = "#")
    -> [PullRequestCommitRow]
  {
    commits.map { commit in
      let numbers = commit.headOf.map { "\(numberPrefix)\($0.number)" }
      return PullRequestCommitRow(
        sha: commit.sha, title: commit.title, author: commit.author,
        date: commit.date.flatMap { try? Date($0, strategy: .iso8601) },
        headOf: numbers.isEmpty ? nil : "Head of \(numbers.joined(separator: ", "))")
    }
  }

  static func commitsState(_ panel: SessionPanelStore) -> PullRequestCommitsState {
    var state = PullRequestCommitsState()
    state.limit = pullRequestCommitsLimit()
    state.query = panel.changesView.commitQuery
    switch panel.commits {
    case .idle: state.isUnavailable = !panel.commitsSupported
    case .loading: state.isLoading = true
    case .failed(let error): state.error = error.message
    case .loaded(let commits):
      state.commits = commitRows(
        commits.commits, numberPrefix: panel.detail.value?.numberPrefix ?? "#")
      state.hasMore = commits.hasMore
    }
    return state
  }

  static func changesSince(_ panel: SessionPanelStore) -> PullRequestChangesSinceState {
    var state = PullRequestChangesSinceState()
    let head = panel.changes.value?.headSha
    let commits = panel.commits.value
    let rows = commitRows(commits?.commits ?? [])
    state.commits = rows.filter { $0.sha != head }.reversed()
    state.selected = panel.sinceSha
    if let since = panel.sinceSha {
      state.label =
        rows.first { $0.sha == since }.map { "Since \($0.shortSha)" } ?? "Since a commit"
    }
    state.isLoading = panel.commits.isLoading
    state.error = panel.commits.error?.message
    if commits?.hasMore == true {
      state.limitNote = "Only the first \(pullRequestCommitsLimit()) commits are listed"
    }
    return state
  }

  /// "Earlier conversations and unavailable diffs": threads and local comments whose file the
  /// diff can't show.
  static func unavailableSection(
    _ panel: SessionPanelStore, files: [StackedDiffFile],
    permissions: ReviewThreadsAdapter.Permissions
  ) -> AnyView? {
    guard panel.isReviewing, let info = panel.detail.value else { return nil }
    let context = ReviewThreadsAdapter.placement(panel, info: info, permissions: permissions)
    let known = { (path: String) in
      files.contains { $0.path == path || $0.previousPath == path || $0.diff?.oldPath == path }
    }
    let threads = context.threads.filter { !known($0.path) }
    let comments = context.localComments.filter { comment in
      !files.contains { $0.path == comment.path }
    }
    var paths: [String] = []
    for path in threads.map(\.path) + comments.map(\.path) where !paths.contains(path) {
      paths.append(path)
    }
    guard !paths.isEmpty else { return nil }
    let groups = paths.map { path in
      group(path, threads: threads, comments: comments, panel: panel, context: context)
    }
    return AnyView(PullRequestUnavailableCommentsView(groups: groups))
  }

  private static func group(
    _ path: String, threads: [ReviewThread], comments: [LocalReviewComment],
    panel: SessionPanelStore, context: ReviewThreadsAdapter.Placement
  ) -> PullRequestUnavailableComments {
    let isShown = panel.changesView.shownEarlierComments.contains(path)
    let hasEarlier =
      threads.contains { $0.path == path && $0.outdated }
      || comments.contains { $0.path == path && panel.isEarlier($0) }
    let actions: AnyView? =
      hasEarlier
      ? AnyView(
        Button(isShown ? "Hide earlier comments" : "Show earlier comments") {
          panel.setEarlierCommentsShown(path, !isShown)
        }
        .buttonStyle(.borderless)
        .font(.caption))
      : nil
    let shownThreads = threads.filter { $0.path == path && (!$0.outdated || isShown) }
      .map { thread in
        ReviewThreadsAdapter.withContext(
          ReviewThreadsAdapter.threadState(
            thread, reply: context.replies[thread.id], canEdit: context.permissions.canEdit,
            caps: context.caps),
          thread)
      }
    let shownLocal = comments.filter { $0.path == path && (!panel.isEarlier($0) || isShown) }
      .map { ReviewThreadsAdapter.localState($0, earlier: panel.isEarlier($0), context: context) }
    return PullRequestUnavailableComments(
      path: path, actions: actions,
      comments: AnyView(
        PullRequestReviewThreadsView(
          threads: shownThreads, localComments: shownLocal, actions: context.actions,
          localActions: context.localActions)))
  }
}
