import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

/// Maps the open pull request's Changes tab state (``SessionPanelStore``) onto
/// ``PullRequestChangesView``, with the web Changes tab's rules and wording.
enum PullRequestChangesAdapter {
  /// The Changes tab, watching review threads and local comments while it shows.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - canEdit: The caller can change the session.
  /// - Returns: The view.
  static func view(_ panel: SessionPanelStore, canEdit: Bool) -> AnyView {
    AnyView(
      PullRequestChangesView(
        state: state(panel, canEdit: canEdit), actions: actions(panel, canEdit: canEdit)
      )
      .whileVisible { _ in await watch(panel) })
  }

  /// Reads the local comments, then the review threads every 10 seconds, while the tab shows.
  private static func watch(_ panel: SessionPanelStore) async {
    await panel.loadLocalComments()
    if panel.detail.value?.capabilities.reviewThreads == true {
      await panel.watchReviewThreads()
    }
  }

  /// What one render of the tab reads from the store.
  struct Inputs {
    let panel: SessionPanelStore
    let canEdit: Bool
    let listing: Listing
    /// Every listed file.
    let files: [StackedDiffFile]
    /// The files the filters leave.
    let visible: [StackedDiffFile]
    let viewed: PullRequestViewedState

    init(_ panel: SessionPanelStore, canEdit: Bool) {
      self.panel = panel
      self.canEdit = canEdit
      listing = Listing(panel)
      files = panel.listedFiles
      visible = panel.visibleFiles
      viewed =
        panel.isReviewing && panel.viewedAvailable ? panel.viewedState : PullRequestViewedState()
    }
  }

  /// The tab's state.
  static func state(_ panel: SessionPanelStore, canEdit: Bool) -> PullRequestChangesState {
    let inputs = Inputs(panel, canEdit: canEdit)
    var state = PullRequestChangesState()
    toolbar(inputs, into: &state)
    notices(inputs, into: &state)
    sidebar(inputs, into: &state)
    state.body =
      panel.changesMode == .commits ? .commits(commitsState(panel)) : body(inputs)
    state.localCommentsFailed = panel.localComments.error != nil
    return state
  }

  private static func toolbar(_ inputs: Inputs, into state: inout PullRequestChangesState) {
    let panel = inputs.panel
    let view = panel.changesView
    let mode = panel.changesMode
    let reviewing = panel.isReviewing
    let files = inputs.files
    let threads = reviewing ? panel.reviewThreads.value?.threads ?? [] : []
    state.showsFileControls = !files.isEmpty && mode != .commits
    if panel.commitsSupported {
      state.offersCommits = true
      state.showsCommitList = mode != .changes
      if mode == .changes { state.changesSince = changesSince(panel) }
    }
    state.canNavigateThreads = threads.contains { !$0.resolved }
    state.isLoadingThreads = reviewing && panel.reviewThreads.isLoading
    state.layout = panel.diffLayout
    state.allCollapsed =
      !inputs.visible.isEmpty && inputs.visible.allSatisfy { panel.isCollapsed($0.path) }
    if mode != .commits {
      let results = panel.findResults
      state.find = findState(
        view, results: results, active: panel.activeFindIndex(results.visible.matches))
    }
    if !files.isEmpty, reviewing, panel.viewedAvailable {
      state.progress = PullRequestViewedProgress(
        viewed: files.count { inputs.viewed.viewed.contains($0.path) }, total: files.count,
        partial: panel.changes.value?.hasMore == true, hideViewed: view.hideViewed)
    }
    if case .commit(let sha) = mode {
      let neighbours = panel.openCommitNeighbours
      state.commitBar = PullRequestCommitBarState(
        sha: sha, title: neighbours.commit?.title, previous: neighbours.previous?.sha,
        next: neighbours.next?.sha)
    }
  }

  private static func sidebar(_ inputs: Inputs, into state: inout PullRequestChangesState) {
    let panel = inputs.panel
    state.pathFilter = panel.changesView.pathFilter
    state.offersFilter = !inputs.files.isEmpty
    state.activePath = panel.changesView.topPath ?? inputs.visible.first?.path
    state.viewedPaths = panel.isReviewing ? inputs.viewed.viewed : []
    state.treeFiles = inputs.visible.map {
      PullRequestTreeFile(path: $0.path, kind: $0.kind, added: $0.added, removed: $0.removed)
    }
    state.treeLoading = inputs.listing.isLoading
    if let error = inputs.listing.error {
      state.treeMessage = error
    } else if inputs.files.isEmpty, !inputs.listing.isLoading {
      state.treeMessage =
        inputs.listing.unavailable ? "Changed files are unavailable." : emptyText(panel)
    }
  }

  /// What the shown list and patch say: the PR's, or a commit's.
  struct Listing {
    var isLoading = false
    var error: String?
    /// The patch can't be diffed here.
    var patchUnavailable: String?
    /// The list is unavailable, truncated or warned about.
    var unavailable = false
    /// The patch is read and parsed.
    var patchReady = false

    init(_ panel: SessionPanelStore) {
      if panel.showsPatchView {
        isLoading = panel.commitPatch.isLoading
        error = panel.commitPatch.error?.message
        patchUnavailable = panel.commitPatch.value?.unavailable
        patchReady = panel.commitPatch.value != nil
        return
      }
      let list = panel.changes
      let patch = panel.files
      isLoading = list.isLoading || patch.isLoading || list == .idle
      error = list.error?.message ?? patch.error?.message
      patchUnavailable = patch.value?.unavailable
      patchReady = patch.value != nil
      if let changes = list.value {
        unavailable = !changes.available || changes.hasMore || changes.warning != nil
      }
    }
  }

  /// What an empty list says: an unreadable commit, a commit without changes, or a PR without
  /// any (the web's `emptyChangesText`).
  private static func emptyText(_ panel: SessionPanelStore) -> String {
    let commit: Bool
    if case .commit = panel.changesMode { commit = true } else { commit = false }
    let since = panel.sinceSha != nil
    if commit || since, panel.commitPatch == .idle {
      return "This commit's diff can't be read here."
    }
    if since { return "No changes since that commit." }
    if commit { return "This commit has no file changes." }
    return "No changes vs base."
  }

  private static func body(_ inputs: Inputs) -> PullRequestChangesBody {
    let panel = inputs.panel
    let listing = inputs.listing
    let view = panel.changesView
    if let error = listing.error { return .message(error, isLoading: false, action: nil) }
    if let unavailable = listing.patchUnavailable {
      return .message(unavailable, isLoading: false, action: nil)
    }
    if inputs.files.isEmpty || !listing.patchReady {
      if listing.isLoading || !listing.patchReady && !inputs.files.isEmpty {
        return .message("Loading changes\u{2026}", isLoading: true, action: nil)
      }
      let text = listing.unavailable ? "Changed files are unavailable." : emptyText(panel)
      return .message(text, isLoading: false, action: nil)
    }
    let matching = ChangedPathFilter.filter(inputs.files, query: view.pathFilter).count
    if view.hideViewed, panel.isReviewing, inputs.visible.isEmpty, matching > 0 {
      return .message(
        "All \(matching) files viewed", isLoading: false,
        action: ("Show viewed", { panel.setHideViewed(false) }))
    }
    if inputs.visible.isEmpty {
      let query = view.pathFilter.trimmingCharacters(in: .whitespacesAndNewlines)
      return .message(
        "No changed files match \"\(query)\"", isLoading: false,
        action: ("Clear filter", { panel.setPathFilter("") }))
    }
    return .diff(diff(inputs))
  }

  private static func diff(_ inputs: Inputs) -> StackedDiffContent {
    let panel = inputs.panel
    let view = panel.changesView
    var content = StackedDiffContent(files: inputs.visible)
    content.layout = panel.diffLayout
    content.collapsed = Set(inputs.visible.map(\.path).filter { panel.isCollapsed($0) })
    content.shownLargeFiles = view.shownLargeFiles
    content.context = panel.showsPatchView ? [:] : panel.fileContext
    if let target = view.findTarget, target.target.kind == .line {
      let matches = panel.findResults.visible.matches
      if let index = panel.activeFindIndex(matches) {
        content.highlight = matches[index]
        content.shownLargeFiles.insert(matches[index].target.path)
      }
    }
    content.scroll = view.scroll
    let reviewing = panel.isReviewing
    let permissions = ReviewThreadsAdapter.permissions(panel, canEdit: inputs.canEdit)
    content.annotations =
      reviewing
      ? ReviewThreadsAdapter.annotations(panel, files: inputs.visible, permissions: permissions)
      : StackedDiffAnnotations()
    for file in inputs.visible {
      content.annotations.headers[file.path] = AnyView(
        headerActions(panel, file: file, viewed: inputs.viewed, reviewing: reviewing))
    }
    content.footer = unavailableSection(panel, files: inputs.files, permissions: permissions)
    return content
  }

  /// The tab's actions over the store.
  static func actions(_ panel: SessionPanelStore, canEdit: Bool) -> PullRequestChangesActions {
    var actions = PullRequestChangesActions()
    actions.loadMoreThreads = { Task { await panel.loadMoreReviewThreads() } }
    actions.dismissResetNotice = { panel.dismissViewedResetNotice() }
    actions.showCommits = { panel.setCommitsShown($0) }
    actions.setSince = { panel.setSinceSha($0) }
    actions.openSince = { Task { await panel.loadCommits() } }
    actions.navigateThread = { panel.navigateUnresolvedThread(forward: $0) }
    actions.setLayout = { panel.diffLayout = $0 }
    actions.toggleAll = { panel.toggleAllCollapsed(panel.visibleFiles.map(\.path)) }
    actions.setFindOpen = { open in if open { panel.openFind() } else { panel.closeFind() } }
    actions.setFindQuery = { panel.setFindQuery($0) }
    actions.toggleMatchCase = { panel.toggleFindMatchCase() }
    actions.toggleRegex = { panel.toggleFindRegex() }
    actions.stepFind = { panel.stepFind(forward: $0) }
    actions.showHidden = { panel.showHiddenFiles() }
    actions.setHideViewed = { panel.setHideViewed($0) }
    actions.backToCommits = { panel.setCommitsShown(true) }
    actions.openCommit = { panel.openCommit($0) }
    actions.setCommitQuery = { panel.setCommitQuery($0) }
    actions.jumpToFile = { panel.jumpToFile($0) }
    actions.setPathFilter = { panel.setPathFilter($0) }
    actions.retryLocalComments = { Task { await panel.loadLocalComments() } }
    var diff = StackedDiffActions()
    diff.toggle = { panel.toggleCollapsed($0) }
    if !panel.showsPatchView {
      diff.expand = { path, gap, expansion in
        Task { await panel.expandContext(path, gap: gap, expansion) }
      }
    }
    diff.showLargeFile = { panel.showLargeFile($0) }
    diff.topFileChanged = { panel.setTopFile($0) }
    diff.scrolled = { panel.scrollFinished($0) }
    actions.diff = diff
    return actions
  }
}
