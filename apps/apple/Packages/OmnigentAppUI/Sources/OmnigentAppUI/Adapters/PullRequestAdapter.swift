import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps the session's stored pull requests (``SessionPanelStore``) onto the right panel's
/// Pull Requests tab.
enum PullRequestAdapter {
  /// A stored state older than this reads "checked … ago"; the server refreshes open PRs after
  /// five minutes while the host is online.
  static let freshness: TimeInterval = 5 * 60

  /// The tab's state.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - now: The current time, for stale states.
  /// - Returns: Loading, the list, the failure, or unsupported on servers that store no PRs.
  static func state(_ panel: SessionPanelStore, now: Date = .now) -> PullRequestsPanelState {
    state(
      features: panel.features, featuresError: panel.featuresError,
      pullRequests: panel.pullRequests, now: now)
  }

  /// The tab's state from the store's values.
  /// - Parameters:
  ///   - features: The server's panel features, once read.
  ///   - featuresError: Why they could not be read.
  ///   - pullRequests: The stored pull requests.
  ///   - now: The current time.
  /// - Returns: The state.
  static func state(
    features: PanelFeatures?, featuresError: CoreError?,
    pullRequests: CreationLoad<SessionPullRequests>, now: Date = .now
  ) -> PullRequestsPanelState {
    guard let features else { return featuresError.map { .failed($0.message) } ?? .loading }
    guard features.pullRequests else { return .unsupported }
    switch pullRequests {
    case .idle, .loading: return .loading
    case .failed(let error): return .failed(error.message)
    case .loaded(let list):
      return .loaded(list.pullRequests.map { summary($0, now: now) }, synced: list.synced)
    }
  }

  /// One row.
  /// - Parameters:
  ///   - pullRequest: The stored PR.
  ///   - now: The current time.
  /// - Returns: The row.
  static func summary(_ pullRequest: SessionPullRequest, now: Date = .now)
    -> PullRequestSummary
  {
    let status: PullRequestSummary.Status =
      switch pullRequest.status {
      case .open: .open
      case .draft: .draft
      case .merged: .merged
      case .closed: .closed
      case .unknown: .unknown
      }
    let detail = [relationship(pullRequest.relationship), checked(pullRequest, now: now)]
      .compactMap(\.self).joined(separator: " \u{00B7} ")
    return PullRequestSummary(
      id: pullRequest.url, number: Int(clamping: pullRequest.number),
      title: pullRequest.title ?? "Pull request #\(pullRequest.number)",
      repo: pullRequest.repository, url: pullRequest.url, status: status,
      detail: detail.isEmpty ? nil : detail)
  }

  private static func relationship(_ relationship: String) -> String? {
    switch relationship {
    case "created": "Created in this session"
    case "worked_on": "Worked on in this session"
    case "attached": "Linked to this session"
    case "inferred": "From the session's branch"
    default: nil
    }
  }

  /// "Checked 2 hr. ago" once the stored state is past the freshness window.
  private static func checked(_ pullRequest: SessionPullRequest, now: Date) -> String? {
    guard let seconds = pullRequest.stateCheckedAt else { return nil }
    let date = Date(timeIntervalSince1970: seconds)
    guard now.timeIntervalSince(date) >= freshness else { return nil }
    let relative = RelativeDateTimeFormatter()
    relative.unitsStyle = .short
    return "Checked \(relative.localizedString(for: date, relativeTo: now))"
  }
}
