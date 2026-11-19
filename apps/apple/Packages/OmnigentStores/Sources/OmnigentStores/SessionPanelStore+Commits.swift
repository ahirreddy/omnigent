public import OmnigentCoreFFI

/// The Changes tab's Commits view and "Changes since", as the web's `usePullRequestCommits` and
/// `usePullRequestCommitDiff`: the commit list at the head the changed-file list shows, one
/// commit's patch, and the changes after a commit up to that head.
extension SessionPanelStore {
  /// What the Commits view says once the server turns out to lack the routes.
  public static let commitsNeedNewerServer = "Commits need an updated Omnigent server."

  /// Reads the commit list at the listed head, once per head; a failed read is tried again.
  public func loadCommits() async {
    guard commitsSupported, let url = openPullRequest, let head = changes.value?.headSha else {
      return
    }
    if case .loading = commits { return }
    if commits.value != nil, commitsReadHead == head { return }
    if commits.value == nil { commits = .loading }
    let result: CreationLoad<PullRequestCommits>?
    do {
      result = try await core.pullRequestCommits(sessionId: sessionID, prUrl: url, headSha: head)
        .map { CreationLoad<PullRequestCommits>.loaded($0) }
    } catch {
      result = .failed(coreError(error))
    }
    guard openPullRequest == url, changes.value?.headSha == head else { return }
    guard let result else {
      commitsWereUnsupported(url)
      return
    }
    commitsReadHead = head
    commits = result
    dropCommitsOutsideTheList()
  }

  /// Reads the open commit's patch, or the changes since the picked commit, once per pick.
  public func loadCommitPatch() async {
    guard let url = openPullRequest, let key = patchKey else { return }
    if commitPatchKey == key, commitPatch.value != nil || commitPatch.isLoading { return }
    commitPatchKey = key
    commitPatch = .loading
    let result: CreationLoad<PullRequestFiles>?
    do {
      if case .commit(let sha) = changesMode {
        result = try await core.pullRequestCommitDiff(
          sessionId: sessionID, prUrl: url, commitSha: sha
        ).map { PullRequestFiles.parsing($0, failure: PullRequestFiles.unreadableCommit) }
      } else if let since = sinceSha, let head = changes.value?.headSha {
        let patch = try await core.pullRequestCompareDiff(
          sessionId: sessionID, prUrl: url, fromSha: since, headSha: head)
        result = PullRequestFiles.parsing(patch, failure: PullRequestFiles.unreadableCommit)
      } else {
        result = .idle
      }
    } catch {
      result = .failed(coreError(error))
    }
    guard openPullRequest == url, commitPatchKey == key else { return }
    guard let result else {
      commitPatch = .idle
      commitPatchKey = nil
      commitsWereUnsupported(url)
      return
    }
    commitPatch = result
  }

  /// The server lacks the commit routes: Changes is the only view left, and it says why.
  private func commitsWereUnsupported(_ url: String) {
    commitsUnsupported.insert(url)
    commits = .idle
    if changesViews[url].map({ $0.mode != .changes || $0.sinceSha != nil }) == true {
      changesViews[url]?.mode = .changes
      changesViews[url]?.sinceSha = nil
      editError = .InvalidState(message: Self.commitsNeedNewerServer)
    }
  }

  /// An open commit or a "since" start the head moved past falls back: the commit list, or
  /// the PR base.
  private func dropCommitsOutsideTheList() {
    guard let listed = commits.value?.commits.map(\.sha) else { return }
    let view = changesView
    if case .commit(let sha) = view.mode, !listed.contains(sha) {
      updateChangesView { $0.mode = .commits }
    }
    if let since = view.sinceSha, !listed.contains(since) {
      updateChangesView { $0.sinceSha = nil }
    }
  }

  /// Keeps the commit list's search.
  /// - Parameter query: The search.
  public func setCommitQuery(_ query: String) {
    updateChangesView { $0.commitQuery = query }
  }

  /// The open commit, with the ones before (older) and after (newer) it in the list.
  public var openCommitNeighbours: PullRequestCommitNeighbours {
    guard case .commit(let sha) = changesMode, let list = commits.value?.commits,
      let index = list.firstIndex(where: { $0.sha == sha })
    else { return PullRequestCommitNeighbours() }
    return PullRequestCommitNeighbours(
      commit: list[index], previous: index > 0 ? list[index - 1] : nil,
      next: index < list.count - 1 ? list[index + 1] : nil)
  }
}

/// The open commit and the commits beside it in the list.
nonisolated public struct PullRequestCommitNeighbours: Equatable, Sendable {
  /// The open commit, when the list has it.
  public var commit: PullRequestCommit?
  /// The older commit.
  public var previous: PullRequestCommit?
  /// The newer commit.
  public var next: PullRequestCommit?
}
