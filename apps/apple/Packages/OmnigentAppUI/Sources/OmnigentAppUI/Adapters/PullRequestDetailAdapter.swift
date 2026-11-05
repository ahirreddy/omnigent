import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps the open pull request's live detail (``SessionPanelStore/detail``) onto the Pull
/// Requests tab's detail view, with the web PR panel's wording.
enum PullRequestDetailAdapter {
  /// The detail view's content; `nil` while the list shows.
  /// - Parameters:
  ///   - panel: The session's panel store.
  ///   - canEdit: The caller can change the session (not read-only).
  /// - Returns: The content.
  static func content(_ panel: SessionPanelStore, canEdit: Bool) -> PullRequestDetailContent? {
    guard panel.openPullRequest != nil else { return nil }
    return content(detail: panel.detail, files: panel.files.value, canEdit: canEdit)
  }

  /// The content from the store's values.
  /// - Parameters:
  ///   - detail: The live detail.
  ///   - files: The parsed patch, once read.
  ///   - canEdit: The caller can change the session.
  /// - Returns: The content.
  static func content(
    detail: CreationLoad<PullRequestInfo>, files: PullRequestFiles?, canEdit: Bool
  ) -> PullRequestDetailContent {
    switch detail {
    case .idle, .loading: return .loading
    case .failed(let error): return .failed(error.message)
    case .loaded(let info):
      guard let pullRequest = info.pullRequest else { return unavailable(info) }
      var state = view(pullRequest, info: info, canEdit: canEdit)
      state.fileCount = files.map(\.files.count)
      return .ready(state)
    }
  }

  /// The status chip's word for a live condition.
  static func status(_ condition: PullRequestCondition) -> PullRequestSummary.Status {
    switch condition {
    case .conflict: .conflicts
    case .checksFailing: .failing
    case .ready: .ready
    case .checksRunning: .running
    case .open: .open
    case .draft: .draft
    case .unknown: .unknown
    case .merged: .merged
    case .closed: .closed
    }
  }

  static func view(_ pullRequest: PullRequestDetail, info: PullRequestInfo, canEdit: Bool)
    -> PullRequestDetailViewState
  {
    let branch = [info.branch ?? pullRequest.headRef, pullRequest.baseRef.map { "\u{2192} \($0)" }]
      .compactMap(\.self).joined(separator: " ")
    let context = [info.repository, branch.isEmpty ? nil : branch]
      .compactMap(\.self).joined(separator: " \u{00B7} ")
    var state = PullRequestDetailViewState(
      url: pullRequest.url, title: pullRequest.title,
      numberLabel: "\(info.numberPrefix)\(pullRequest.number)",
      status: status(pullRequest.condition), context: context,
      providerName: info.providerName ?? "GitHub")
    state.body = pullRequest.body
    (state.checks, state.checksNote) = checks(pullRequest)
    state.showsReviewers = pullRequest.reviewers != nil
    state.reviewers = pullRequest.reviewers?.map(reviewer) ?? []
    state.showsLabels = pullRequest.labels != nil
    state.labels = pullRequest.labels?.map(label) ?? []
    state.comments = pullRequest.comments.enumerated().map { index, comment in
      PullRequestCommentRow(
        id: comment.url ?? "\(index)", author: comment.author ?? "Unknown",
        date: comment.createdAt.flatMap { try? Date($0, strategy: .iso8601) },
        body: comment.body, url: comment.url.flatMap(URL.init(string:)))
    }
    state.commentsPartial = pullRequest.commentsPartial
    let caps = info.capabilities
    let open = pullRequest.status == .open || pullRequest.status == .draft
    if canEdit, caps.merging, open, pullRequest.reportsMergeState {
      state.merge = merge(pullRequest)
    }
    state.canEditLabels = canEdit && caps.labelEditing
    state.canEditReviewers = canEdit && caps.reviewerEditing
    state.canComment = canEdit && caps.commentPosting
    return state
  }

  /// The merge area, as the web's merge button decides it.
  static func merge(_ pullRequest: PullRequestDetail) -> PullRequestMergeState {
    if pullRequest.autoMergeMethod != nil { return .autoMerge }
    let status = pullRequest.mergeStateStatus?.uppercased()
    let caveats = [
      "UNSTABLE": "Checks that aren\u{2019}t required are failing or still running.",
      "HAS_HOOKS":
        "The repository\u{2019}s pre-receive hooks run on merge and can still reject it.",
    ]
    let mergeable = status == "CLEAN" || status.map { caveats[$0] != nil } == true
    if mergeable, pullRequest.headSha != nil { return .ready(status.flatMap { caveats[$0] }) }
    if status == nil || status == "UNKNOWN" || mergeable {
      return .checking("Checking whether it can merge\u{2026}")
    }
    let blocked = [
      "BLOCKED": "Required checks or reviews haven\u{2019}t passed.",
      "BEHIND": "Update the branch first.",
      "DIRTY": "Resolve conflicts first.",
      "DRAFT": "Mark the pull request ready for review first.",
    ]
    return .blocked(
      status.flatMap { blocked[$0] } ?? "GitHub reports that it can\u{2019}t merge yet.")
  }

  private static func checks(_ pullRequest: PullRequestDetail)
    -> (groups: [PullRequestCheckGroup], note: String?)
  {
    let checks = pullRequest.checks
    let note: String? =
      !pullRequest.checksSupported
      ? "Checks can\u{2019}t be read with the signed-in account."
      : checks.partial ? "Some checks are unavailable. Counts include only the checks loaded." : nil
    let buckets: [(PullRequestCheckGroup.Bucket, CheckBucket)] = [
      (.failed, .failing), (.pending, .pending), (.passed, .passing), (.cancelled, .cancelled),
      (.skipped, .skipped),
    ]
    let groups = buckets.compactMap { bucket, core -> PullRequestCheckGroup? in
      let count = count(checks, core)
      guard count > 0 else { return nil }
      return PullRequestCheckGroup(
        bucket: bucket, count: Int(clamping: count),
        runs: checks.runs.filter { $0.bucket == core }.map {
          PullRequestCheckGroup.Run(name: $0.name, url: $0.url.flatMap(URL.init(string:)))
        })
    }
    return (groups, note)
  }

  private static func count(_ checks: PullRequestChecks, _ bucket: CheckBucket) -> UInt64 {
    switch bucket {
    case .passing: checks.passing
    case .failing: checks.failing
    case .pending: checks.pending
    case .cancelled: checks.cancelled
    case .skipped: checks.skipped
    }
  }

  /// A reviewer chip; its id names the kind, so a team and a user never collide.
  static func reviewer(_ reviewer: PullRequestReviewer) -> PullRequestChip {
    let (detail, symbol): (String, String) =
      switch reviewer.state {
      case .pending: ("Pending", "clock")
      case .approved: ("Approved", "checkmark.circle")
      case .commented: ("Commented", "text.bubble")
      case .changesRequested: ("Changes requested", "exclamationmark.bubble")
      case .dismissed: ("Dismissed", "minus.circle")
      }
    return PullRequestChip(
      id: reviewerID(login: reviewer.login, kind: reviewer.kind), title: reviewer.login,
      detail: detail, systemImage: reviewer.kind == .team ? "person.2" : symbol)
  }

  static func reviewerID(login: String, kind: ReviewerKind) -> String {
    "\(kind == .team ? "team" : "user"):\(login.lowercased())"
  }

  /// The reviewer a chip id names.
  static func reviewerTarget(_ id: String) -> ReviewerTarget? {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    return ReviewerTarget(login: parts[1], kind: parts[0] == "team" ? .team : .user)
  }

  static func label(_ label: PullRequestLabel) -> PullRequestChip {
    PullRequestChip(
      id: label.name, title: label.name, detail: label.description,
      color: label.color.flatMap { UInt32($0, radix: 16) })
  }

  private static func unavailable(_ info: PullRequestInfo) -> PullRequestDetailContent {
    let provider = info.providerName ?? "the git provider"
    switch info.availability {
    case .notAGitRepository:
      return .unavailable(
        title: "Not a git repository",
        message:
          "This workspace isn\u{2019}t a git checkout, so there\u{2019}s no branch or PR to show.",
        systemImage: "arrow.triangle.branch")
    case .hostOutdated:
      return .unavailable(
        title: "Update your host",
        message: "The Pull Requests tab needs the host running Omnigent 0.13.0 or later.",
        systemImage: "arrow.down.circle")
    case .unsupportedRemote(let host):
      return .unavailable(
        title: "No supported remote",
        message: host.map {
          "The workspace\u{2019}s remote is on \($0), which isn\u{2019}t a supported git provider."
        }
          ?? "This workspace\u{2019}s remote isn\u{2019}t on a supported git provider.",
        systemImage: "server.rack")
    case .noCli(let cli):
      return .unavailable(
        title: "\(cli) not found",
        message: "Install \(cli) on the host to see this pull request and its checks.",
        systemImage: "terminal")
    case .repositoryUnresolved(let hint):
      return .unavailable(
        title: "Can\u{2019}t reach the upstream repo",
        message: hint ?? "Sign in to \(provider) on the session\u{2019}s host, then refresh.",
        systemImage: "key")
    case .ready, .noPullRequest, .unavailable:
      return .unavailable(
        title: "Pull request unavailable",
        message: info.warnings.first
          ?? "The host couldn\u{2019}t read this pull request from \(provider).",
        systemImage: "exclamationmark.circle")
    }
  }
}
