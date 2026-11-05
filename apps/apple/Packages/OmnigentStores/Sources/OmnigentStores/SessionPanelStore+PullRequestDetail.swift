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
    }
    await reloadDetail()
  }

  /// Back to the list of linked pull requests.
  public func showPullRequestList() {
    guard openPullRequest != nil else { return }
    openPullRequest = nil
    detail = .idle
    files = .idle
    editError = nil
  }

  /// Re-reads the open PR's detail and patch. The shown detail stays while it reloads, and a
  /// read started later wins.
  public func reloadDetail() async {
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
      await reloadFiles(url: url, generation: current)
    }
  }

  private func reloadFiles(url: String, generation current: Int) async {
    if files.value == nil { files = .loading }
    let result: CreationLoad<PullRequestFiles>
    do {
      let patch = try await core.pullRequestPatch(sessionId: sessionID, prUrl: url)
      let diffs = try parseUnifiedDiff(patch: patch.patch).map(WorkspaceMapping.fileDiff)
      result = .loaded(PullRequestFiles(files: diffs, unavailable: patch.unavailable))
    } catch {
      result = .failed(coreError(error))
    }
    guard current == detailGeneration, openPullRequest == url, files != result else { return }
    files = result
  }

  /// Reads each open linked PR's live condition (checks, conflicts) for the composer's chip.
  /// Merged and closed PRs cannot change, so their stored state stands.
  public func refreshLiveConditions() async {
    guard let linked = pullRequests.value?.pullRequests else { return }
    let open = linked.filter { $0.status != .merged && $0.status != .closed }.map(\.url)
    for url in open {
      // A PR the host cannot read keeps its stored state.
      guard let info = try? await core.pullRequestInfo(sessionId: sessionID, prUrl: url),
        let pullRequest = info.pullRequest, pullRequest.url == url
      else { continue }
      setLiveCondition(pullRequest.condition, for: url)
    }
  }

  func setLiveCondition(_ condition: PullRequestCondition, for url: String) {
    if liveConditions[url] != condition { liveConditions[url] = condition }
  }
}
