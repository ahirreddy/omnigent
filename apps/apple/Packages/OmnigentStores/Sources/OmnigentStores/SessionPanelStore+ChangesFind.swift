import Foundation
import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// The Changes tab's expanding context, find and conversation navigation, as the web's
/// `PullRequestChangesTab` keeps them.
extension SessionPanelStore {
  /// The diff scrolled as request `token` asked; a view shown later does not scroll again.
  /// - Parameter token: The request's token.
  public func scrollFinished(_ token: Int) {
    if changesView.scroll?.token == token { updateChangesView { $0.scroll = nil } }
  }

  // MARK: - Expanding context

  /// Expands a gap of unchanged lines, reading the file's text first when needed.
  /// - Parameters:
  ///   - path: The file.
  ///   - gap: The gap.
  ///   - expansion: Which way.
  public func expandContext(_ path: String, gap: DiffGap, _ expansion: DiffExpansion) async {
    if fileContext[path]?.text == nil {
      guard await loadFileContext(path) else { return }
    }
    guard let state = fileContext[path] else { return }
    let refreshed =
      gap.count == nil
      ? DiffContext.gaps(
        listedFiles.first { $0.path == path }?.diff ?? OmnigentWorkspaceUI.FileDiff.empty,
        lineCount: state.text?.lines.count
      ).first { $0.index == gap.index } ?? gap
      : gap
    fileContext[path] = state.expanding(refreshed, expansion)
  }

  /// Reads `path`'s text at the head for expanding context.
  /// - Returns: Whether it was read.
  private func loadFileContext(_ path: String) async -> Bool {
    guard let url = openPullRequest, let info = detail.value, let pullRequest = info.pullRequest
    else { return false }
    let previous = listedFiles.first { $0.path == path }?.renamedFrom
    var state = fileContext[path] ?? DiffContextState()
    guard !state.isLoading else { return false }
    state.isLoading = true
    state.failure = nil
    fileContext[path] = state
    let head = pullRequest.headSha
    do {
      let contents = try await core.pullRequestFileContents(
        sessionId: sessionID, path: path, base: info.baseRef, prUrl: url, previousPath: previous,
        baseSha: pullRequest.baseSha, headSha: head)
      guard openPullRequest == url, filesHead == head else { return false }
      state.text = DiffContextText(
        lines: DiffContextState.lines(of: contents.after ?? contents.before ?? ""))
      state.isLoading = false
      fileContext[path] = state
      return true
    } catch {
      guard openPullRequest == url else { return false }
      state.isLoading = false
      state.failure = coreError(error).message
      fileContext[path] = state
      return false
    }
  }

  // MARK: - Find

  /// Opens the find bar, or with it open keeps it (the view selects the query).
  public func openFind() {
    updateChangesView { $0.find.isOpen = true }
  }

  /// Closes the find bar.
  public func closeFind() {
    updateChangesView { view in
      view.find.isOpen = false
      view.findTarget = nil
    }
  }

  /// Changes the query; the match at or below the top of the view becomes the active one.
  /// - Parameter query: The query.
  public func setFindQuery(_ query: String) {
    updateChangesView { view in
      view.find.query = query
      view.findTarget = nil
    }
    seedFindMatch()
  }

  /// Turns match case on or off.
  public func toggleFindMatchCase() {
    updateChangesView { view in
      view.find.matchCase.toggle()
      view.findTarget = nil
    }
    seedFindMatch()
  }

  /// Turns regular expressions on or off.
  public func toggleFindRegex() {
    updateChangesView { view in
      view.find.regex.toggle()
      view.findTarget = nil
    }
    seedFindMatch()
  }

  /// The visible files the find bar searches.
  public var visibleFiles: [StackedDiffFile] {
    let hidden = changesView.hideViewed && isReviewing ? viewedState.viewed : []
    return ChangedPathFilter.visible(listedFiles, query: changesView.pathFilter, hiding: hidden)
  }

  /// The query's matches in the visible files, and in the files the filters hide.
  public var findResults: (visible: DiffFindResult, hidden: DiffFindResult) {
    let view = changesView
    guard view.find.isOpen, changesMode != .commits else {
      return (DiffFindResult(), DiffFindResult())
    }
    let visible = visibleFiles
    let shown = Set(visible.map(\.path))
    let search = { (files: [StackedDiffFile]) in
      DiffFind.matches(
        in: DiffFind.corpus(files), query: view.find.query, matchCase: view.find.matchCase,
        regex: view.find.regex)
    }
    return (search(visible), search(listedFiles.filter { !shown.contains($0.path) }))
  }

  /// The active match's index among `matches`.
  public func activeFindIndex(_ matches: [DiffFindMatch]) -> Int? {
    guard let target = changesView.findTarget, !matches.isEmpty else { return nil }
    return DiffFind.refreshedIndex(matches, previous: target)
  }

  /// Steps to the next or previous match, wrapping.
  /// - Parameter forward: Toward the end.
  public func stepFind(forward: Bool) {
    let matches = findResults.visible.matches
    guard !matches.isEmpty else { return }
    let index = DiffFind.step(
      from: activeFindIndex(matches), forward: forward, count: matches.count)
    show(matches[index])
  }

  private func seedFindMatch() {
    let matches = findResults.visible.matches
    guard !matches.isEmpty else { return }
    let index = DiffFind.firstAtOrBelow(
      matches, paths: visibleFiles.map(\.path), top: changesView.topPath)
    show(matches[index])
  }

  private func show(_ match: DiffFindMatch) {
    updateChangesView { $0.findTarget = match }
    reveal(match.target.path)
    if match.target.kind == .line, let side = match.target.side, let line = match.target.line {
      scroll(to: .line(path: match.target.path, side: side, line: line))
    } else {
      scroll(to: .file(match.target.path))
    }
  }
}

extension SessionPanelStore {
  /// Steps to the next or previous unresolved review conversation, wrapping: its file opens,
  /// filters hiding it clear, an outdated one's earlier comments show, and the diff scrolls to
  /// it.
  /// - Parameter forward: Toward the end.
  public func navigateUnresolvedThread(forward: Bool) {
    guard isReviewing else { return }
    let unresolved = (reviewThreads.value?.threads ?? []).filter { !$0.resolved }
    guard !unresolved.isEmpty else { return }
    let current = unresolved.firstIndex { $0.id == changesView.focusedThread }
    let start = current ?? (forward ? -1 : 0)
    let index = (start + (forward ? 1 : -1) + unresolved.count) % unresolved.count
    let next = unresolved[index]
    let file = listedFiles.first {
      $0.path == next.path || $0.previousPath == next.path || $0.diff?.oldPath == next.path
    }
    if next.outdated { setEarlierCommentsShown(file?.path ?? next.path, true) }
    updateChangesView { $0.focusedThread = next.id }
    guard let file else { return }
    if !visibleFiles.contains(where: { $0.path == file.path }) {
      let view = changesView
      if !ChangedPathFilter.matches(file, query: view.pathFilter) { setPathFilter("") }
      if view.hideViewed, viewedState.viewed.contains(file.path) { setHideViewed(false) }
    }
    reveal(file.path)
    updateChangesView { $0.topPath = file.path }
    if !next.outdated, !next.onFile, let line = next.line, let side = next.side {
      scroll(to: .line(path: file.path, side: side == .left ? .old : .new, line: line))
    } else {
      scroll(to: .file(file.path))
    }
  }
}

extension CreationLoad {
  /// Whether a read is in flight.
  public var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }
}

extension OmnigentWorkspaceUI.FileDiff {
  /// A diff with nothing in it.
  static let empty = OmnigentWorkspaceUI.FileDiff(
    oldPath: nil, newPath: nil, change: .modified, hunks: [], splitRows: [], added: 0, removed: 0)
}
