public import OmnigentCoreFFI

/// The panel's changes to the session's pull requests. One runs at a time (``pendingEdit``);
/// a failure is kept in ``editError`` until the next change or a new PR is shown.
extension SessionPanelStore {
  /// Links the PR at `url` and shows it.
  /// - Parameter url: The PR's address.
  /// - Returns: Whether it was linked.
  @discardableResult
  public func linkPullRequest(_ url: String) async -> Bool {
    let info = await edit(.link) { core, session in
      try await core.linkPullRequest(sessionId: session, url: url)
    }
    guard let info else { return false }
    await reloadPullRequests()
    if let selected = info.selectedUrl { await showPullRequest(selected) }
    return true
  }

  /// Unlinks the PR at `url`; the list shows when it was the open one.
  /// - Parameter url: The PR's address.
  public func unlinkPullRequest(_ url: String) async {
    let info = await edit(.unlink(url: url)) { core, session in
      try await core.unlinkPullRequest(sessionId: session, url: url)
    }
    guard info != nil else { return }
    if openPullRequest == url { showPullRequestList() }
    await reloadPullRequests()
  }

  /// Reads the labels the open PR's repository offers, once per PR.
  public func loadRepositoryLabels() async {
    guard let url = openPullRequest, repositoryLabels.value == nil else { return }
    repositoryLabels = .loading
    let result: CreationLoad<RepositoryLabels>
    do {
      result = .loaded(try await core.pullRequestRepositoryLabels(sessionId: sessionID, prUrl: url))
    } catch {
      result = .failed(coreError(error))
    }
    if openPullRequest == url { repositoryLabels = result }
  }

  /// Adds or removes one label on the open PR.
  /// - Parameters:
  ///   - name: The label.
  ///   - add: Add it, or remove it.
  public func setLabel(_ name: String, added add: Bool) async {
    guard let url = openPullRequest else { return }
    let labels = await edit(.labels) { core, session in
      try await core.updatePullRequestLabels(
        sessionId: session, prUrl: url, add: add ? [name] : [], remove: add ? [] : [name])
    }
    guard let labels, openPullRequest == url, var info = detail.value else { return }
    info.pullRequest?.labels = labels
    detail = .loaded(info)
  }

  /// Reads who a review of the open PR can be requested from, once per PR.
  public func loadReviewCandidates() async {
    guard let url = openPullRequest, reviewCandidates.value == nil else { return }
    reviewCandidates = .loading
    let result: CreationLoad<ReviewCandidates>
    do {
      result = .loaded(try await core.pullRequestReviewCandidates(sessionId: sessionID, prUrl: url))
    } catch {
      result = .failed(coreError(error))
    }
    if openPullRequest == url { reviewCandidates = result }
  }

  /// Requests a review from `reviewer`, or withdraws the pending request.
  /// - Parameters:
  ///   - reviewer: The user or team.
  ///   - request: Request it, or withdraw it.
  public func setReviewer(_ reviewer: ReviewerTarget, requested request: Bool) async {
    guard let url = openPullRequest else { return }
    let reviewers = await edit(.reviewers) { core, session in
      try await core.updatePullRequestReviewers(
        sessionId: session, prUrl: url, add: request ? [reviewer] : [],
        remove: request ? [] : [reviewer])
    }
    guard let reviewers, openPullRequest == url, var info = detail.value else { return }
    info.pullRequest?.reviewers = reviewers
    detail = .loaded(info)
  }

  /// Reads the merge methods the open PR's repository allows, once per PR.
  public func loadMergeOptions() async {
    guard let url = openPullRequest, mergeOptions.value == nil else { return }
    mergeOptions = .loading
    let result: CreationLoad<MergeOptions>
    do {
      result = .loaded(try await core.pullRequestMergeOptions(sessionId: sessionID, prUrl: url))
    } catch {
      result = .failed(coreError(error))
    }
    if openPullRequest == url { mergeOptions = result }
  }

  /// Merges the open PR at the head the panel shows; GitHub refuses when the branch moved.
  /// - Parameter method: How to merge.
  /// - Returns: Whether the provider accepted the merge.
  @discardableResult
  public func mergePullRequest(_ method: MergeMethod) async -> Bool {
    guard let url = openPullRequest, let head = detail.value?.pullRequest?.headSha else {
      return false
    }
    let merged: Void? = await edit(.merge) { core, session in
      try await core.mergePullRequest(
        sessionId: session, prUrl: url, method: method, expectedHead: head)
    }
    guard merged != nil else { return false }
    await reloadDetail()
    await reloadPullRequests()
    return true
  }

  /// Turns off the open PR's auto-merge.
  public func disableAutoMerge() async {
    guard let url = openPullRequest else { return }
    let disabled: Void? = await edit(.autoMerge) { core, session in
      try await core.disablePullRequestAutoMerge(sessionId: session, prUrl: url)
    }
    if disabled != nil { await reloadDetail() }
  }

  /// Posts a conversation comment on the open PR and shows it.
  /// - Parameter body: Markdown.
  /// - Returns: Whether it was posted.
  @discardableResult
  public func postComment(_ body: String) async -> Bool {
    guard let url = openPullRequest else { return false }
    let comment = await edit(.comment) { core, session in
      try await core.postPullRequestComment(sessionId: session, prUrl: url, body: body)
    }
    guard let comment else { return false }
    if openPullRequest == url, var info = detail.value {
      info.pullRequest?.comments.append(comment)
      detail = .loaded(info)
    }
    return true
  }

  /// Runs one change, keeping its failure in ``editError``; `nil` when it failed or another
  /// change is in flight.
  private func edit<Value>(
    _ kind: PullRequestEdit,
    _ operation: (ClientCore, String) async throws -> Value
  ) async -> Value? {
    guard pendingEdit == nil else { return nil }
    pendingEdit = kind
    if editError != nil { editError = nil }
    defer { pendingEdit = nil }
    do {
      return try await operation(core, sessionID)
    } catch {
      editError = coreError(error)
      return nil
    }
  }

  /// Clears the last change's failure.
  public func dismissEditError() {
    if editError != nil { editError = nil }
  }
}
