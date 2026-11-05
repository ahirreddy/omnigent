import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// The Pull Requests tab's detail, choices and actions over ``SessionPanelStore``: the open PR
/// read live from the session's host, its files as a stacked diff, and the web panel's changes
/// (link and unlink, labels, reviewers, merge, comments).
enum PullRequestPanelSlots {
  /// The tab's extras.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - canEdit: The caller can change the session; read-only viewers only browse.
  /// - Returns: The extras.
  static func extras(_ panel: SessionPanelStore, canEdit: Bool) -> PullRequestPanelExtras {
    var extras = PullRequestPanelExtras()
    extras.detail = PullRequestDetailAdapter.content(panel, canEdit: canEdit)
    if panel.openPullRequest != nil { extras.changes = changes(panel) }
    extras.labelChoices = choices(panel.repositoryLabels) {
      $0.labels.map(PullRequestDetailAdapter.label)
    }
    extras.reviewerChoices = choices(panel.reviewCandidates) { candidates in
      candidates.candidates.map {
        PullRequestChip(
          id: PullRequestDetailAdapter.reviewerID(login: $0.login, kind: $0.kind),
          title: $0.login, detail: $0.name, systemImage: $0.kind == .team ? "person.2" : "person")
      }
    }
    extras.mergeMethods = choices(panel.mergeOptions, mergeMethods)
    extras.isBusy = panel.pendingEdit != nil
    extras.error = panel.editError?.message
    extras.actions = actions(panel, canEdit: canEdit)
    return extras
  }

  private static func actions(_ panel: SessionPanelStore, canEdit: Bool) -> PullRequestPanelActions
  {
    var actions = PullRequestPanelActions()
    actions.select = { url in Task { await panel.showPullRequest(url) } }
    actions.showList = { panel.showPullRequestList() }
    actions.refresh = {
      Task {
        await panel.reloadPullRequests()
        await panel.reloadDetail()
      }
    }
    actions.dismissError = { panel.dismissEditError() }
    guard canEdit else { return actions }
    actions.link = { url, done in
      Task { done(await panel.linkPullRequest(url)) }
    }
    actions.unlink = { url in Task { await panel.unlinkPullRequest(url) } }
    actions.loadLabels = { Task { await panel.loadRepositoryLabels() } }
    actions.setLabel = { name, add in Task { await panel.setLabel(name, added: add) } }
    actions.loadReviewers = { Task { await panel.loadReviewCandidates() } }
    actions.setReviewer = { id, request in
      guard let target = PullRequestDetailAdapter.reviewerTarget(id) else { return }
      Task { await panel.setReviewer(target, requested: request) }
    }
    actions.loadMergeMethods = { Task { await panel.loadMergeOptions() } }
    actions.merge = { id in
      guard let method = mergeMethod(id) else { return }
      Task { await panel.mergePullRequest(method) }
    }
    actions.disableAutoMerge = { Task { await panel.disableAutoMerge() } }
    actions.comment = { body, done in
      Task { done(await panel.postComment(body)) }
    }
    return actions
  }

  /// The merge methods, the repository's default first, named as GitHub's merge menu names them.
  static func mergeMethods(_ options: MergeOptions) -> [PullRequestChip] {
    let ordered =
      options.defaultMethod.map { method in [method] + options.methods.filter { $0 != method } }
      ?? options.methods
    return ordered.map { method in
      switch method {
      case .squash: PullRequestChip(id: "squash", title: "Squash and Merge")
      case .merge: PullRequestChip(id: "merge", title: "Create a Merge Commit")
      case .rebase: PullRequestChip(id: "rebase", title: "Rebase and Merge")
      }
    }
  }

  static func mergeMethod(_ id: String) -> MergeMethod? {
    switch id {
    case "squash": .squash
    case "merge": .merge
    case "rebase": .rebase
    default: nil
    }
  }

  private static func choices<Value>(
    _ load: CreationLoad<Value>, _ map: (Value) -> [PullRequestChip]
  ) -> PullRequestChoices {
    switch load {
    case .idle: .idle
    case .loading: .loading
    case .failed(let error): .failed(error.message)
    case .loaded(let value): .loaded(map(value))
    }
  }

  /// The Changes tab: every file in one scroll, or why there is none.
  private static func changes(_ panel: SessionPanelStore) -> AnyView {
    switch panel.files {
    case .idle, .loading:
      AnyView(
        ProgressView("Loading changes\u{2026}").frame(maxWidth: .infinity, maxHeight: .infinity))
    case .failed(let error):
      AnyView(
        ContentUnavailableView(
          "Couldn't Load the Changes", systemImage: "exclamationmark.triangle",
          description: Text(error.message)))
    case .loaded(let files) where files.unavailable != nil || files.files.isEmpty:
      AnyView(
        ContentUnavailableView(
          files.unavailable == nil ? "No Changes" : "Diff Unavailable",
          systemImage: "plus.forwardslash.minus",
          description: Text(files.unavailable ?? "This pull request changes no files.")))
    case .loaded(let files):
      AnyView(StackedDiffView(files: files.files))
    }
  }
}
