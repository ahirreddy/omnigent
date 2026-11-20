import Foundation
import OmnigentCoreFFI
import OmnigentStores

/// `sessions.*`: the caller's sessions as the app lists them, a page of the server's list, and a
/// session's pull request.
extension LiveExtensionHostServices {
  /// The first sessions the sidebar already lists, newest change first; `null` before the list
  /// is read, or for a page after the first.
  func cachedSessions(_ params: String?) throws -> String {
    let request = try extensionSessionPageRequest(paramsJson: params)
    let list = connection.sessionList
    guard request.after == nil, list.isLoaded else { return "null" }
    let rows = list.sessionsByID.values
      .filter { !$0.isArchived }
      .sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
      .map { Self.row($0, unread: list.unreadIDs.contains($0.id)) }
    return extensionCachedSessionsResult(rows: rows, limit: request.limit)
  }

  /// A page of the server's list, with this app's unread marks.
  func sessionPage(_ params: String?) async throws -> String {
    let request = try extensionSessionPageRequest(paramsJson: params)
    guard let core = connection.core else { throw Self.unavailable("Session list") }
    let list = connection.sessionList
    return try await sessionReads.run {
      var page = try await core.extensionSessionRows(request: request)
      page.rows = page.rows.map { row in
        var row = row
        row.unread = list.unreadIDs.contains(row.id)
        return row
      }
      return try extensionSessionPageResult(page: page)
    }
  }

  /// The session's pull request, live from its host; while the host is offline, the one the
  /// server last stored, once it knows. Its page becomes one the extension may open.
  func pullRequest(_ params: String?) async throws -> String {
    let sessionID = try extensionSessionId(paramsJson: params)
    guard let core = connection.core else { throw Self.unavailable("Pull request") }
    let found = try await pullRequestReads.run {
      try await Self.readPullRequest(core, sessionID: sessionID)
    }
    guard let found else { return "null" }
    let result = extensionPullRequestResult(
      number: found.number, title: found.title, state: found.state, url: found.url)
    if result != "null" { externalURLs.insert(found.url) }
    return result
  }

  private struct FoundPullRequest {
    let number: UInt64
    let title: String
    let state: String
    let url: String
  }

  private static func readPullRequest(
    _ core: ClientCore, sessionID: String
  ) async throws -> FoundPullRequest? {
    do {
      let info = try await core.pullRequestInfo(sessionId: sessionID, prUrl: nil)
      guard case .ready = info.availability, let detail = info.pullRequest else { return nil }
      return FoundPullRequest(
        number: detail.number, title: detail.title, state: wireState(detail.status),
        url: detail.url)
    } catch let error as CoreError where error.isHostOffline {
      // The host is offline: answer with what the server stored, once it has imported them.
      let stored = try await core.sessionPullRequests(sessionId: sessionID)
      guard let first = stored.pullRequests.first else {
        if stored.synced { return nil }
        throw error
      }
      guard first.status != .unknown else { throw error }
      return FoundPullRequest(
        number: first.number, title: first.title ?? "", state: wireState(first.status),
        url: first.url)
    }
  }

  /// The provider's state as the web hands it on (`OPEN`, `MERGED`, `CLOSED`).
  private static func wireState(_ status: PullRequestStatus) -> String {
    switch status {
    case .open, .draft: "OPEN"
    case .merged: "MERGED"
    case .closed: "CLOSED"
    case .unknown: "UNKNOWN"
    }
  }

  /// A listed session as an extension sees it.
  static func row(_ session: SessionSummary, unread: Bool) -> ExtensionSessionRow {
    let status: String =
      switch session.status {
      case .needsResponse: "waiting"
      case .running: "running"
      case .idle: session.failureMessage == nil ? "idle" : "failed"
      }
    return ExtensionSessionRow(
      id: session.id, title: session.title, titleProvisional: false, status: status,
      unread: unread, workspace: session.workspace.isEmpty ? nil : session.workspace,
      gitBranch: nil, projectId: session.projectId, createdAt: Double(session.createdAt),
      updatedAt: Double(session.updatedAt))
  }
}
