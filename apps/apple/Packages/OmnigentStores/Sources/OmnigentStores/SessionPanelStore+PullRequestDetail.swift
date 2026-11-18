import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// A patch of the open pull request, parsed: the whole PR, one commit, or the changes since one.
nonisolated public struct PullRequestFiles: Equatable, Sendable {
  /// Each file's diff, in patch order.
  public var files: [OmnigentWorkspaceUI.FileDiff]
  /// Why the host cannot diff the PR.
  public var unavailable: String?
  /// The head the patch was read at, when the host names it.
  public var headSha: String?
  /// The base the patch was read at, when the host names it.
  public var baseSha: String?

  /// Creates the files.
  /// - Parameters:
  ///   - files: The diffs.
  ///   - unavailable: Why there are none.
  ///   - headSha: The head it was read at.
  ///   - baseSha: The base it was read at.
  public init(
    files: [OmnigentWorkspaceUI.FileDiff], unavailable: String? = nil, headSha: String? = nil,
    baseSha: String? = nil
  ) {
    self.files = files
    self.unavailable = unavailable
    self.headSha = headSha
    self.baseSha = baseSha
  }

  /// The diff of `path`, by its current or old path.
  /// - Parameter path: The path.
  /// - Returns: The diff.
  public func diff(for path: String) -> OmnigentWorkspaceUI.FileDiff? {
    files.first { $0.path == path } ?? files.first { $0.oldPath == path }
  }

  /// A patch, parsed, or `failure` when it cannot be read.
  static func parsing(_ patch: PullRequestPatch, failure: String) -> CreationLoad<Self> {
    do {
      let diffs = try parseUnifiedDiff(patch: patch.patch).map(WorkspaceMapping.fileDiff)
      return .loaded(
        Self(
          files: diffs, unavailable: patch.unavailable, headSha: patch.headSha,
          baseSha: patch.baseSha))
    } catch {
      return .failed(.InvalidState(message: failure))
    }
  }

  /// What a PR patch that cannot be parsed says.
  static let unreadablePatch =
    "Couldn\u{2019}t read the PR diff. Refresh or open the PR on its provider."
  /// What a commit's patch that cannot be parsed says.
  static let unreadableCommit =
    "Couldn\u{2019}t read this commit\u{2019}s diff. Refresh or open it on its provider."
}

/// A change to a pull request the panel makes.
nonisolated public enum PullRequestEdit: Equatable, Sendable {
  /// Linking a PR by address.
  case link
  /// Unlinking a PR.
  case unlink(url: String)
  /// Adding or removing a label.
  case labels
  /// Requesting or withdrawing a review.
  case reviewers
  /// Merging.
  case merge
  /// Turning off auto-merge.
  case autoMerge
  /// Posting a comment.
  case comment
  /// Changing the title or description.
  case details
  /// Replying to or starting a review thread.
  case reviewComment
}

extension SessionPanelStore {
  /// Shows `url` in detail and reads it from the session's host.
  /// - Parameter url: The linked PR.
  public func showPullRequest(_ url: String) async {
    if openPullRequest != url {
      openPullRequest = url
      detail = .loading
      files = .idle
      repositoryLabels = .idle
      reviewCandidates = .idle
      mergeOptions = .idle
      editError = nil
      clearChanges()
      clearReviewThreads()
      restartPolling()
    }
    await reloadDetail()
  }

  /// Back to the list of linked pull requests.
  public func showPullRequestList() {
    guard openPullRequest != nil else { return }
    openPullRequest = nil
    detail = .idle
    editError = nil
    clearChanges()
    clearReviewThreads()
    restartPolling()
  }

  /// Forgets what the Changes tab read for the PR shown before.
  private func clearChanges() {
    files = .idle
    changes = .idle
    filesHead = nil
    fileContext = [:]
    commits = .idle
    commitPatch = .idle
    commitPatchKey = nil
  }

  private func clearReviewThreads() {
    reviewThreads = .idle
    newReviewThread = nil
    reviewReplies = [:]
  }

  /// Re-reads the open PR's detail and patch. The shown detail stays while it reloads, and a
  /// read started later wins.
  /// - Parameter refreshingFiles: Re-read the patch too; a poll re-reads it only when the
  ///   PR's head moved.
  public func reloadDetail(refreshingFiles: Bool = true) async {
    await readDetail(refreshingFiles: refreshingFiles)
    resumePollingIfRested()
  }

  private func readDetail(refreshingFiles: Bool) async {
    guard let url = openPullRequest else { return }
    detailGeneration += 1
    let current = detailGeneration
    let result: CreationLoad<PullRequestInfo>
    do {
      result = .loaded(try await core.pullRequestInfo(sessionId: sessionID, prUrl: url))
    } catch {
      result = .failed(coreError(error))
    }
    guard current == detailGeneration, openPullRequest == url else { return }
    if detail != result { detail = result }
    if let pullRequest = result.value?.pullRequest {
      setLiveCondition(pullRequest.condition, for: url)
      let moved = files == .idle || filesHead != pullRequest.headSha
      if refreshingFiles || moved {
        await reloadFiles(url: url, pullRequest: pullRequest, generation: current)
      }
    }
  }

  /// Reads the changed-file list and the patch pinned to the revision the detail shows, as the
  /// web's Changes tab reads both at `base:head`.
  private func reloadFiles(url: String, pullRequest: PullRequestDetail, generation current: Int)
    async
  {
    if files.value == nil { files = .loading }
    if changes.value == nil { changes = .loading }
    let base = pullRequest.baseSha
    let head = pullRequest.headSha
    async let patchRead = readPatch(url: url, base: base, head: head)
    async let listRead = readChanges(url: url, base: base, head: head)
    let patch = await patchRead
    let list = await listRead
    guard current == detailGeneration, openPullRequest == url else { return }
    let moved = filesHead != head
    if moved { fileContext = [:] }
    filesHead = head
    if files != patch { files = patch }
    if changes != list { changes = list }
    seedViewedCollapses()
    revealLocalCommentIfReady()
    // The commit list follows the listed head, as the web's query keyed by it.
    if moved, commits.value != nil || changesMode != .changes { await loadCommits() }
  }

  private func readPatch(url: String, base: String?, head: String?) async
    -> CreationLoad<PullRequestFiles>
  {
    do {
      let patch = try await core.pullRequestPatch(
        sessionId: sessionID, prUrl: url, baseSha: base, headSha: head)
      return PullRequestFiles.parsing(patch, failure: PullRequestFiles.unreadablePatch)
    } catch {
      return .failed(coreError(error))
    }
  }

  private func readChanges(url: String, base: String?, head: String?) async
    -> CreationLoad<PullRequestChanges>
  {
    do {
      return .loaded(
        try await core.pullRequestChanges(
          sessionId: sessionID, prUrl: url, baseSha: base, headSha: head))
    } catch {
      return .failed(coreError(error))
    }
  }

  /// Reads each open linked PR's live condition (checks, conflicts) for the composer's chip.
  /// Merged and closed PRs cannot change, so their stored state stands, and a PR the host
  /// cannot read keeps its stored state.
  /// - Returns: Whether a read found the session's host offline.
  @discardableResult
  public func refreshLiveConditions() async -> Bool {
    guard let linked = pullRequests.value?.pullRequests else { return false }
    let open = linked.filter { pullRequest in
      pullRequest.status != .merged && pullRequest.status != .closed
        && liveConditions[pullRequest.url] != .merged
        && liveConditions[pullRequest.url] != .closed
    }
    var offline = false
    for url in open.map(\.url) {
      let info: PullRequestInfo
      do {
        info = try await core.pullRequestInfo(sessionId: sessionID, prUrl: url)
      } catch {
        offline = offline || coreError(error).isHostOffline
        continue
      }
      guard let pullRequest = info.pullRequest, pullRequest.url == url else { continue }
      setLiveCondition(pullRequest.condition, for: url)
    }
    return offline
  }

  func setLiveCondition(_ condition: PullRequestCondition, for url: String) {
    if liveConditions[url] != condition { liveConditions[url] = condition }
  }
}
