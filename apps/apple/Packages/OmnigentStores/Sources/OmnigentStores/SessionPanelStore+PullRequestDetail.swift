import OmnigentCoreFFI
public import OmnigentWorkspaceUI

/// The open pull request's changed files, parsed from its patch.
nonisolated public struct PullRequestFiles: Equatable, Sendable {
  /// Each file's diff, in patch order.
  public var files: [OmnigentWorkspaceUI.FileDiff]
  /// Why the host cannot diff the PR.
  public var unavailable: String?

  /// Creates the files.
  /// - Parameters:
  ///   - files: The diffs.
  ///   - unavailable: Why there are none.
  public init(files: [OmnigentWorkspaceUI.FileDiff], unavailable: String? = nil) {
    self.files = files
    self.unavailable = unavailable
  }
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
      filesHead = nil
      restartPolling()
    }
    await reloadDetail()
  }

  /// Back to the list of linked pull requests.
  public func showPullRequestList() {
    guard openPullRequest != nil else { return }
    openPullRequest = nil
    detail = .idle
    files = .idle
    filesHead = nil
    editError = nil
    restartPolling()
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
        await reloadFiles(url: url, head: pullRequest.headSha, generation: current)
      }
    }
  }

  private func reloadFiles(url: String, head: String?, generation current: Int) async {
    if files.value == nil { files = .loading }
    let result: CreationLoad<PullRequestFiles>
    do {
      let patch = try await core.pullRequestPatch(sessionId: sessionID, prUrl: url)
      let diffs = try parseUnifiedDiff(patch: patch.patch).map(WorkspaceMapping.fileDiff)
      result = .loaded(PullRequestFiles(files: diffs, unavailable: patch.unavailable))
    } catch {
      result = .failed(coreError(error))
    }
    guard current == detailGeneration, openPullRequest == url else { return }
    filesHead = head
    if files != result { files = result }
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
