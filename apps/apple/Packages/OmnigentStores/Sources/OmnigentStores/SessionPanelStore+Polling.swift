public import OmnigentCoreFFI

/// Who keeps the session's pull requests fresh while it is on screen.
nonisolated public enum PullRequestWatcher: Hashable, Sendable {
  /// The Pull Requests tab: the open PR at the panel's cadence, otherwise each row's.
  case panel
  /// The composer's chip: the linked PRs at the list cadence.
  case composer
}

/// What the poll waits on; a test passes one it fires by hand.
nonisolated public protocol PullRequestPollTimer: Sendable {
  /// Waits `duration`, returning early when the task is cancelled.
  /// - Parameter duration: How long to wait.
  func wait(_ duration: Duration) async
}

/// The real clock.
nonisolated struct SystemPullRequestPollTimer: PullRequestPollTimer {
  func wait(_ duration: Duration) async {
    await sleepUnlessCancelled(for: duration)
  }
}

/// The poll's running counts: time since each read, and host-offline retries in a row.
nonisolated struct PullRequestPollProgress: Equatable, Sendable {
  var sinceDetail: Duration = .zero
  var sinceList: Duration = .zero
  var offlineRetries: UInt32 = 0
}

/// Polls the open PR and the linked ones as the web does while checks run and merges settle:
/// every 5 seconds (10 on a host that links PRs) for the open PR until it settles, every 30 for
/// list rows and the composer while any linked PR is open, with backoff while the host is
/// offline. Only watchers on screen poll (``watch(_:resumed:)``).
extension SessionPanelStore {
  /// Keeps the session's PRs fresh until the calling task is cancelled.
  /// - Parameters:
  ///   - watcher: Who is watching.
  ///   - resumed: The watcher shows again after being hidden, so it re-reads first.
  public func watch(_ watcher: PullRequestWatcher, resumed: Bool = false) async {
    if resumed, !Task.isCancelled { await refreshForWatcher(watcher) }
    guard !Task.isCancelled else { return }
    watchers[watcher, default: 0] += 1
    restartPolling()
    await untilCancelled()
    let remaining = (watchers[watcher] ?? 1) - 1
    watchers[watcher] = remaining > 0 ? remaining : nil
    restartPolling()
  }

  /// Starts the poll over from the current state, or stops it when nobody watches.
  func restartPolling() {
    pollTask?.cancel()
    pollTask = nil
    pollRests = false
    guard !watchers.isEmpty else { return }
    let timer = pollTimer
    // A detail that already found the host offline starts with the backoff.
    let offline = detailPollInterval != nil && detail.error?.isHostOffline == true
    pollTask = Task { [weak self] in
      var progress = PullRequestPollProgress(offlineRetries: offline ? 1 : 0)
      while let delay = self?.nextPollDelay(progress) {
        await timer.wait(delay)
        guard !Task.isCancelled, let self else { return }
        progress = await pollDue(progress, after: delay)
      }
      guard !Task.isCancelled else { return }
      self?.pollRests = true
    }
  }

  /// Starts a poll that rested once a read from outside it finds something to watch again.
  func resumePollingIfRested() {
    if pollRests { restartPolling() }
  }

  /// The open PR's interval while the panel shows it.
  var detailPollInterval: Duration? {
    guard watchers[.panel] != nil, openPullRequest != nil else { return nil }
    let polling = detail.value?.polling ?? pullRequestPollingWithoutInfo()
    return polling.panelMs.map { .milliseconds($0) }
  }

  /// The linked PRs' interval while the list or the composer shows them.
  var listPollInterval: Duration? {
    let panelList = watchers[.panel] != nil && openPullRequest == nil
    guard panelList || watchers[.composer] != nil, offersPullRequests else { return nil }
    return pullRequestLinkedPollMs(statuses: linkedStatuses).map { .milliseconds($0) }
  }

  /// Each linked PR's status, a merge or close its host reported since included.
  var linkedStatuses: [PullRequestStatus] {
    (pullRequests.value?.pullRequests ?? []).map { pullRequest in
      switch liveConditions[pullRequest.url] {
      case .merged: .merged
      case .closed: .closed
      default: pullRequest.status
      }
    }
  }

  /// The wait before the next read; `nil` rests until a watcher, a refresh or a turn end.
  func nextPollDelay(_ progress: PullRequestPollProgress) -> Duration? {
    if progress.offlineRetries > 0 {
      return pullRequestHostOfflineRetryMs(attempt: progress.offlineRetries - 1)
        .map { .milliseconds($0) }
    }
    let detail = detailPollInterval.map { max($0 - progress.sinceDetail, .zero) }
    let list = listPollInterval.map { max($0 - progress.sinceList, .zero) }
    return [detail, list].compactMap(\.self).min()
  }

  /// Runs the reads that are due after waiting `delay`, and counts host-offline failures.
  private func pollDue(_ progress: PullRequestPollProgress, after delay: Duration) async
    -> PullRequestPollProgress
  {
    var next = progress
    next.sinceDetail += delay
    next.sinceList += delay
    let retrying = progress.offlineRetries > 0
    var offline = false
    if let interval = detailPollInterval, retrying || next.sinceDetail >= interval {
      await reloadDetail(refreshingFiles: false)
      next.sinceDetail = .zero
      offline = offline || detail.error?.isHostOffline == true
    }
    if let interval = listPollInterval, retrying || next.sinceList >= interval {
      offline = await readPullRequests() || offline
      next.sinceList = .zero
    }
    next.offlineRetries = offline ? progress.offlineRetries + 1 : 0
    return next
  }

  /// A watcher shows again: what it shows is read now rather than at its next tick.
  private func refreshForWatcher(_ watcher: PullRequestWatcher) async {
    if watcher == .panel, openPullRequest != nil {
      await reloadDetail(refreshingFiles: false)
    } else if pullRequests != .idle {
      await reloadPullRequests()
    }
  }

  /// Returns when the calling task is cancelled.
  private func untilCancelled() async {
    let (stream, continuation) = AsyncStream<Never>.makeStream()
    await withTaskCancellationHandler {
      for await _ in stream {}
    } onCancel: {
      continuation.finish()
    }
  }
}

extension CreationLoad {
  /// The failure, when the load failed.
  public var error: CoreError? {
    if case .failed(let error) = self { return error }
    return nil
  }
}
