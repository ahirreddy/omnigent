import OmnigentCoreFFI

/// Which top-level pages the server offers (Automations, Usage, Canvas, sharing). They are read
/// for each connection the core makes, not when a view appears: a read racing a reconnect fails,
/// and the reconnect's own read replaces it.
extension ConnectionStore {
  /// Failed refreshes retried without an issue while pages already show; after a wake the
  /// network can take a moment to return.
  static let quietOfferedPagesRetries = 2

  /// Reads the offered pages again now: each connect, a return to the foreground, a renewed
  /// credential and Retry call it. While signed in, a failed read is tried again after a
  /// backoff, and the pages last read keep showing.
  public func reloadOfferedPages() {
    guard let pages, case .connected(let server) = phase else { return }
    pages.offeredBelong(to: "\(server.baseUrl)\n\(server.userId)")
    workflows?.belong(to: "\(server.baseUrl)\n\(server.userId)")
    if let extensions {
      extensions.belong(to: "\(server.baseUrl)\n\(server.userId)")
      Task { await extensions.reload() }
    }
    offeredPagesReload?.cancel()
    offeredPagesReload = Task { [weak self] in
      var failures = 0
      while let delay = await self?.readOfferedPages(pages, failuresBefore: failures) {
        failures += 1
        await sleepUnlessCancelled(for: delay)
        if Task.isCancelled { return }
      }
    }
  }

  /// One read of the offered pages.
  /// - Parameters:
  ///   - pages: The store that keeps them.
  ///   - failuresBefore: The failed reads in a row before this one.
  /// - Returns: How long to wait before the next try, or `nil` when there is none to make.
  private func readOfferedPages(_ pages: PagesStore, failuresBefore: Int) async -> Duration? {
    let read = await pages.readOffered()
    guard !Task.isCancelled else { return nil }
    switch read {
    case .read:
      clearOfferedPagesIssue()
      return nil
    case .superseded:
      return nil
    case .failed(let error):
      // The connection ended under the read: the next connect reads them again.
      guard isSignedIn else { return nil }
      let failures = failuresBefore + 1
      if pages.offered == nil || failures > Self.quietOfferedPagesRetries {
        recordOfferedPagesIssue(error)
      }
      return offeredPagesRetryDelay(failures)
    }
  }

  /// Records the failure once per run of failures, updating it while the user keeps it.
  private func recordOfferedPagesIssue(_ error: CoreError) {
    guard let id = offeredPagesIssueID else {
      offeredPagesIssueID = record(scope: .connection, error)
      return
    }
    // Dismissed: it stays away until a read works and a later one fails.
    guard let index = issues.firstIndex(where: { $0.id == id }) else { return }
    issues[index] = CoreIssue(id: id, scope: .connection, error: error)
  }

  private func clearOfferedPagesIssue() {
    guard let id = offeredPagesIssueID else { return }
    offeredPagesIssueID = nil
    issues.removeAll { $0.id == id }
  }

  /// The wait before the next read after `failures` failed ones: 1, 2, 4… seconds, at most a
  /// minute.
  nonisolated static func offeredPagesBackoff(_ failures: Int) -> Duration {
    .seconds(min(60, 1 << min(max(failures - 1, 0), 6)))
  }
}
