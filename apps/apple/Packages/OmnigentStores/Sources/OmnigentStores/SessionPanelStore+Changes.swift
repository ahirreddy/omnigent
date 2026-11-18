import Foundation
import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// What the Changes tab shows: the pull request's changed files, its commit list, or one
/// commit's patch.
nonisolated public enum PullRequestChangesMode: Hashable, Sendable {
  /// The changed files.
  case changes
  /// The commit list.
  case commits
  /// One commit's patch.
  case commit(String)
}

/// The Changes tab's view of one pull request, kept while the app runs, as the web's
/// `useChangesViewState`.
nonisolated public struct PullRequestChangesTabState: Equatable, Sendable {
  /// What it shows.
  public var mode = PullRequestChangesMode.changes
  /// In Changes, only the changes after this commit, up to the head.
  public var sinceSha: String?
  /// The path filter.
  public var pathFilter = ""
  /// Hide viewed files.
  public var hideViewed = false
  /// The commit list's search.
  public var commitQuery = ""
  /// The find bar.
  public var find = DiffFindState()
  /// The match the reader navigated to; `nil` until one is chosen.
  public var findTarget: DiffFindMatch?
  /// Files shown for now (a jump, a find match), apart from the reader's collapses.
  public var revealed: Set<String> = []
  /// Files whose earlier (outdated) comments show.
  public var shownEarlierComments: Set<String> = []
  /// The head whose "lost their viewed marks" notice was dismissed.
  public var dismissedResetHead: String?
  /// Files collapsed in Changes.
  public var collapsed: Set<String> = []
  /// Collapses viewed marks made; a new head expands them again.
  public var markCollapsed: Set<String> = []
  /// The head viewed files were last collapsed for.
  public var seededHead: String?
  /// The commit or "since" start the commit collapses belong to.
  public var commitKey: String?
  /// Files collapsed in that commit's view.
  public var commitCollapsed: Set<String> = []
  /// Files revealed in that commit's view.
  public var commitRevealed: Set<String> = []
  /// Large files shown anyway.
  public var shownLargeFiles: Set<String> = []
  /// The file at the top of the view.
  public var topPath: String?
  /// Where the diff scrolls next.
  public var scroll: StackedDiffScroll?
  /// The review thread navigated to.
  public var focusedThread: String?

  /// The initial view.
  public init() {}
}

/// The Changes tab's state and actions, as the web's `PullRequestChangesTab` keeps them.
extension SessionPanelStore {
  static let diffLayoutKey = "omnigent.pullRequestDiffLayout"
  static let commentDestinationKey = "omnigent.pullRequestCommentDestination"

  /// The open pull request's view.
  public var changesView: PullRequestChangesTabState {
    openPullRequest.flatMap { changesViews[$0] } ?? PullRequestChangesTabState()
  }

  /// Changes the open pull request's view.
  func updateChangesView(_ change: (inout PullRequestChangesTabState) -> Void) {
    guard let url = openPullRequest else { return }
    var view = changesViews[url] ?? PullRequestChangesTabState()
    change(&view)
    if changesViews[url] != view { changesViews[url] = view }
  }

  // MARK: - What shows

  /// Whether the Commits view is offered: the host lists commits, the list is pinned to a
  /// head, and the server has the routes.
  public var commitsSupported: Bool {
    guard let url = openPullRequest, detail.value?.capabilities.commitHistory == true,
      changes.value?.headSha != nil
    else { return false }
    return !commitsUnsupported.contains(url)
  }

  /// What the tab shows; Changes without the Commits view.
  public var changesMode: PullRequestChangesMode {
    commitsSupported ? changesView.mode : .changes
  }

  /// The commit Changes starts after, when one is picked.
  public var sinceSha: String? {
    changesMode == .changes && commitsSupported ? changesView.sinceSha : nil
  }

  /// Whether a commit's patch or the changes since one stand in for the PR's patch.
  public var showsPatchView: Bool {
    if case .commit = changesMode { return true }
    return sinceSha != nil
  }

  /// Review tools (threads, viewed marks, line comments) belong to the whole PR diff.
  public var isReviewing: Bool { changesMode == .changes && sinceSha == nil }

  /// The head both the list and the patch were read at; viewed marks need it.
  public var renderedHead: String? {
    guard let head = changes.value?.headSha, files.value?.headSha == head else { return nil }
    return head
  }

  /// The files the tab lists: the PR's from the provider's list with their diffs, or the
  /// files a commit's patch changes.
  public var listedFiles: [StackedDiffFile] {
    if showsPatchView {
      return commitPatch.value?.files.map(StackedDiffFile.init(diff:)) ?? []
    }
    let patch = files.value
    return (changes.value?.files ?? []).map { file in
      let diff =
        patch?.files.first { $0.path == file.path }
        ?? file.previousPath.flatMap { previous in patch?.files.first { $0.oldPath == previous } }
      return StackedDiffFile(
        path: file.path, previousPath: file.previousPath, kind: Self.kind(file.status),
        added: file.linesAdded, removed: file.linesRemoved, diff: diff)
    }
  }

  static func kind(_ status: PullRequestFileStatus) -> ChangedFileKind {
    switch status {
    case .created: .added
    case .modified: .modified
    case .deleted: .deleted
    case .renamed: .renamed
    }
  }

  // MARK: - Viewed marks

  /// The open pull request as viewed marks name it; `nil` while it is not known.
  public var viewedIdentity: PullRequestViewedIdentity? {
    guard let url = openPullRequest else { return nil }
    let linked =
      detail.value?.linked.first { $0.url == url }
      ?? pullRequests.value?.pullRequests.first { $0.url == url }
    return linked.map {
      PullRequestViewedIdentity(
        provider: $0.provider, host: $0.host, repository: $0.repository, number: $0.number)
    }
  }

  /// Who, which pull request and which head viewed marks are read for.
  private struct ViewedKey {
    let scope: PullRequestViewedScope
    let identity: PullRequestViewedIdentity
    let head: String
  }

  private var viewedKey: ViewedKey? {
    guard let scope = viewedScope?(), let identity = viewedIdentity, let head = renderedHead
    else { return nil }
    return ViewedKey(scope: scope, identity: identity, head: head)
  }

  /// Whether viewed marks can be read and set now.
  public var viewedAvailable: Bool { viewedKey != nil }

  /// Each file's fingerprint in the PR's patch at the rendered head.
  private func fingerprint(head: String) -> (String) -> String {
    let prints = Dictionary(
      (files.value?.files ?? []).compactMap { diff in
        DiffFingerprint.of(diff).map { (diff.path, $0) }
      },
      uniquingKeysWith: { first, _ in first })
    return { prints[$0] ?? DiffFingerprint.unverified(head: head) }
  }

  /// The viewed and changed files; empty while marks are unavailable.
  public var viewedState: PullRequestViewedState {
    guard let key = viewedKey else { return PullRequestViewedState() }
    return viewedMarks.state(key.scope, key.identity, fingerprint: fingerprint(head: key.head))
  }

  /// Marks a file viewed (collapsing it) or not.
  /// - Parameter path: The file.
  public func toggleViewed(_ path: String) {
    guard let key = viewedKey else { return }
    let marking = !viewedState.viewed.contains(path)
    viewedMarks.set(
      [path], viewed: marking, key.scope, key.identity, fingerprint: fingerprint(head: key.head))
    guard marking else { return }
    updateChangesView { view in
      if !view.collapsed.contains(path) { view.markCollapsed.insert(path) }
      view.revealed.remove(path)
      view.collapsed.insert(path)
    }
  }

  /// Viewed files start collapsed once per rendered head; the collapses marks made on the
  /// previous head expand again, while the reader's own stay.
  func seedViewedCollapses() {
    guard viewedAvailable, let head = renderedHead, changesView.seededHead != head else { return }
    let viewed = viewedState.viewed
    updateChangesView { view in
      let owned = viewed.filter { !view.collapsed.contains($0) || view.markCollapsed.contains($0) }
      view.collapsed = view.collapsed.subtracting(view.markCollapsed).union(viewed)
      view.markCollapsed = owned
      view.seededHead = head
    }
  }

  /// Hides the "lost their viewed marks" notice for the rendered head.
  public func dismissViewedResetNotice() {
    let head = renderedHead
    updateChangesView { $0.dismissedResetHead = head }
  }

  // MARK: - Collapse, reveal, jump

  /// Whether `path` shows collapsed in the current view.
  public func isCollapsed(_ path: String) -> Bool {
    let view = changesView
    if showsPatchView, view.commitKey == patchKey {
      return view.commitCollapsed.contains(path) && !view.commitRevealed.contains(path)
    }
    if showsPatchView { return false }
    return view.collapsed.contains(path) && !view.revealed.contains(path)
  }

  /// The key a commit view's own collapses belong to.
  var patchKey: String? {
    if case .commit(let sha) = changesMode { return sha }
    return sinceSha.map { "since:\($0)" }
  }

  /// Collapses or expands one file; the reader then owns its collapse.
  /// - Parameter path: The file.
  public func toggleCollapsed(_ path: String) {
    let collapse = !isCollapsed(path)
    let key = patchKey
    updateChangesView { view in
      if let key {
        Self.resetCommitView(&view, key: key)
        view.commitRevealed.remove(path)
        if collapse { view.commitCollapsed.insert(path) } else { view.commitCollapsed.remove(path) }
      } else {
        view.revealed.remove(path)
        view.markCollapsed.remove(path)
        if collapse { view.collapsed.insert(path) } else { view.collapsed.remove(path) }
      }
    }
  }

  /// Collapses every visible file, or expands them all when all are collapsed.
  /// - Parameter paths: The visible files.
  public func toggleAllCollapsed(_ paths: [String]) {
    let collapse = !paths.allSatisfy { isCollapsed($0) }
    let key = patchKey
    updateChangesView { view in
      if let key {
        Self.resetCommitView(&view, key: key)
        view.commitRevealed.subtract(paths)
        if collapse {
          view.commitCollapsed.formUnion(paths)
        } else {
          view.commitCollapsed.subtract(paths)
        }
      } else {
        view.revealed.subtract(paths)
        view.markCollapsed.subtract(paths)
        if collapse { view.collapsed.formUnion(paths) } else { view.collapsed.subtract(paths) }
      }
    }
  }

  private static func resetCommitView(_ view: inout PullRequestChangesTabState, key: String) {
    guard view.commitKey != key else { return }
    view.commitKey = key
    view.commitCollapsed = []
    view.commitRevealed = []
  }

  /// Shows `path` even while collapsed.
  func reveal(_ path: String) {
    let key = patchKey
    updateChangesView { view in
      if let key {
        Self.resetCommitView(&view, key: key)
        view.commitRevealed.insert(path)
      } else {
        view.revealed.insert(path)
      }
    }
  }

  /// Scrolls the diff to `target`.
  func scroll(to target: StackedDiffScroll.Target) {
    scrollTokens += 1
    let request = StackedDiffScroll(token: scrollTokens, target: target)
    updateChangesView { $0.scroll = request }
  }

  /// Jumps to a file from the file list: it opens and scrolls to its header.
  /// - Parameter path: The file.
  public func jumpToFile(_ path: String) {
    reveal(path)
    updateChangesView { $0.topPath = path }
    scroll(to: .file(path))
  }

  /// Notes the file at the top of the view as the diff scrolls.
  /// - Parameter path: The file.
  public func setTopFile(_ path: String) {
    if changesView.topPath != path { updateChangesView { $0.topPath = path } }
  }

  /// Shows a large file's diff.
  /// - Parameter path: The file.
  public func showLargeFile(_ path: String) {
    updateChangesView { _ = $0.shownLargeFiles.insert(path) }
  }

  /// Shows or hides a file's earlier (outdated) comments.
  /// - Parameters:
  ///   - path: The file.
  ///   - shown: Show them.
  public func setEarlierCommentsShown(_ path: String, _ shown: Bool) {
    updateChangesView { view in
      if shown {
        view.shownEarlierComments.insert(path)
      } else {
        view.shownEarlierComments.remove(path)
      }
    }
  }

  // MARK: - Filters and modes

  /// Narrows the list by path.
  /// - Parameter query: The filter text.
  public func setPathFilter(_ query: String) {
    updateChangesView { $0.pathFilter = query }
  }

  /// Hides or shows viewed files.
  /// - Parameter hide: Hide them.
  public func setHideViewed(_ hide: Bool) {
    updateChangesView { $0.hideViewed = hide }
  }

  /// Clears the filters that hide matches: the path filter, and Hide viewed in Changes.
  public func showHiddenFiles() {
    let reviewing = isReviewing
    updateChangesView { view in
      view.pathFilter = ""
      if reviewing { view.hideViewed = false }
    }
  }

  /// Shows the changed files or the commit list, leaving an open commit.
  /// - Parameter commits: Show the commit list.
  public func setCommitsShown(_ commits: Bool) {
    updateChangesView { view in
      view.mode = commits ? .commits : .changes
      view.findTarget = nil
    }
    if commits { Task { await loadCommits() } }
  }

  /// Opens one commit's patch.
  /// - Parameter sha: The commit.
  public func openCommit(_ sha: String) {
    updateChangesView { view in
      view.mode = .commit(sha)
      view.findTarget = nil
    }
    Task { await loadCommitPatch() }
  }

  /// Shows only the changes after `sha` up to the head, or every change from the PR base.
  /// - Parameter sha: The commit, or `nil` for the PR base.
  public func setSinceSha(_ sha: String?) {
    updateChangesView { view in
      view.sinceSha = sha
      view.findTarget = nil
    }
    if sha != nil { Task { await loadCommitPatch() } }
  }
}
