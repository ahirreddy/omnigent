import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Where a session's managed sandbox stands, for the Pull Requests tab's offline wording.
enum PullRequestSandbox: Equatable {
  /// No sandbox, or it is up.
  case awake
  /// Asleep until a message starts it.
  case asleep
  /// A message or Reconnect is starting it.
  case starting

  /// The sandbox of a session with `header`: a resumable host that is offline sleeps, and
  /// starts while a turn runs or its launch moves.
  static func of(_ header: OmnigentCoreFFI.SessionHeader?) -> Self {
    guard let header, let settings = header.settings, settings.hostResumable == true,
      settings.hostOnline == false
    else { return .awake }
    let launching = SandboxAdapter.launchNote(header.sandboxLaunch).map { $0.standing != .failed }
    return header.status == .running || launching == true ? .starting : .asleep
  }
}

/// The list rows' live extras and the offline wording, as the web's `PullRequestListRow` and
/// `storedPullRequestHint` have them.
extension PullRequestAdapter {
  /// Each listed PR's failing and running checks, or the badge saying why it can't be read.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - sandbox: The session's sandbox.
  /// - Returns: The extras, by URL.
  static func rows(_ panel: SessionPanelStore, sandbox: PullRequestSandbox)
    -> [String: PullRequestRowExtras]
  {
    let linked = panel.pullRequests.value?.pullRequests ?? []
    let offline = panel.linkedHostOffline || sandbox != .awake
    var rows: [String: PullRequestRowExtras] = [:]
    for pullRequest in linked {
      var row = PullRequestRowExtras()
      if offline {
        row.offline = PullRequestOfflineNote(
          title: offlineTitle(sandbox), hint: storedHint(pullRequest, sandbox: sandbox))
      } else if let checks = panel.liveChecks[pullRequest.url] {
        row.failing = Int(clamping: checks.failing)
        row.pending = Int(clamping: checks.pending)
      } else if panel.liveConditions[pullRequest.url] != nil, pullRequest.status == .open {
        row.checksUnavailable = true
      }
      if !row.isEmpty { rows[pullRequest.url] = row }
    }
    return rows
  }

  /// "Host offline", "Sandbox asleep" or "Sandbox starting".
  static func offlineTitle(_ sandbox: PullRequestSandbox) -> String {
    switch sandbox {
    case .awake: "Host offline"
    case .asleep: "Sandbox asleep"
    case .starting: "Sandbox starting"
    }
  }

  /// When the stored PR last synced and what loads its details.
  static func storedHint(_ pullRequest: SessionPullRequest, sandbox: PullRequestSandbox)
    -> String
  {
    let synced = pullRequest.stateCheckedAt.map { seconds in
      let date = Date(timeIntervalSince1970: seconds)
      return "Last sync time: \(date.formatted(date: .abbreviated, time: .shortened)). "
    }
    let next =
      switch sandbox {
      case .awake: "To load the PR details, please reconnect the session\u{2019}s host."
      case .asleep: "To load the PR details, send a message to start the session\u{2019}s sandbox."
      case .starting:
        "Starting the session\u{2019}s sandbox. The PR details will load once it\u{2019}s back online."
      }
    return (synced ?? "") + next
  }

  /// Why the list hasn't synced while the host or sandbox is down; `nil` otherwise.
  static func notSyncedHint(_ panel: SessionPanelStore, sandbox: PullRequestSandbox) -> String? {
    guard panel.pullRequests.value?.synced == false,
      panel.linkedHostOffline || sandbox != .awake
    else { return nil }
    let lead = "This session\u{2019}s PRs haven\u{2019}t synced to the server yet."
    return switch sandbox {
    case .awake: "\(lead) To load them, please reconnect the session\u{2019}s host."
    case .asleep: "\(lead) To load them, send a message to start the session\u{2019}s sandbox."
    case .starting: "\(lead) Starting the session\u{2019}s sandbox to load them."
    }
  }

  /// The provider's wording for the list, from the first linked PR that names one.
  static func wording(_ panel: SessionPanelStore) -> PullRequestProviderWording {
    let named = panel.pullRequests.value?.pullRequests.first { $0.providerName != nil }
    guard let named, let name = named.providerName else { return PullRequestProviderWording() }
    return PullRequestProviderWording(name: name, requestName: named.requestName ?? "pull request")
  }
}
