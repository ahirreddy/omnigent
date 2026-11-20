import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

private let url = "https://github.com/o/r/pull/7"

private func detail(
  condition: PullRequestCondition = .open, mergeState: String? = "CLEAN", autoMerge: String? = nil,
  checks: PullRequestChecks? = nil, checksSupported: Bool = true
) -> PullRequestDetail {
  PullRequestDetail(
    number: 7, title: "Fix login", url: url, status: .open, condition: condition, author: "ann",
    baseRef: "main", headRef: "fix", headSha: "abc", baseSha: "base", body: "Body",
    checks: checks
      ?? PullRequestChecks(
        passing: 0, failing: 0, pending: 0, cancelled: 0, skipped: 0, total: 0, partial: false,
        runs: []),
    checksSupported: checksSupported,
    comments: [
      PullRequestComment(
        author: "bob", body: "LGTM", createdAt: "2026-01-02T03:04:05Z", url: "https://c")
    ],
    commentsPartial: false, timelineEvents: [], timelinePartial: false,
    reviewers: [
      PullRequestReviewer(login: "Core", kind: .team, state: .pending),
      PullRequestReviewer(login: "bob", kind: .user, state: .approved),
    ],
    labels: [PullRequestLabel(name: "bug", color: "d73a4a", description: "Broken")],
    mergeStateStatus: mergeState, reportsMergeState: true, autoMergeMethod: autoMerge)
}

/// What the panel can do: labels, merging and comments unless a test says otherwise.
private func prCapabilities(
  labels: Bool = true, merging: Bool = true, comments: Bool = true, reviewers: Bool = false,
  details: Bool = false, attachments: Bool = false
) -> PullRequestCapabilities {
  PullRequestCapabilities(
    labelEditing: labels, merging: merging, commentPosting: comments, reviewerEditing: reviewers,
    detailsEditing: details, attachmentUploads: attachments, reviewThreads: false,
    reviewThreadReplies: false, reviewThreadCreation: false, commitHistory: false,
    lineCounts: true, linkedPrDiff: true, accountSwitching: false, baseRemoteSelection: false,
    mergeAsAccount: false)
}

private func info(
  _ pullRequest: PullRequestDetail?, availability: PullRequestAvailability = .ready,
  capabilities: PullRequestCapabilities = prCapabilities()
) -> PullRequestInfo {
  PullRequestInfo(
    availability: availability, providerName: "GitHub", numberPrefix: "#", branch: "fix",
    repository: "o/r", baseRef: "main", selectedUrl: url, trackingAvailable: true, linked: [],
    warnings: [], capabilities: capabilities, pullRequest: pullRequest,
    polling: pullRequestPollingWithoutInfo())
}

@MainActor
struct PullRequestDetailAdapterTests {
  @Test func theDetailCarriesTheHeaderPeopleAndWhatTheCallerCanChange() throws {
    let content = PullRequestDetailAdapter.content(
      detail: .loaded(info(detail(condition: .ready))), files: nil, canEdit: true)
    guard case .ready(let state) = content else {
      Issue.record("expected the detail, got \(content)")
      return
    }
    #expect(state.numberLabel == "#7")
    #expect(state.status == .ready)
    #expect(state.context == "o/r \u{00B7} fix \u{2192} main")
    #expect(state.reviewers.map(\.id) == ["team:core", "user:bob"])
    #expect(state.reviewers.last?.detail == "Approved")
    #expect(state.labels.first?.color == 0xD73A4A)
    #expect(state.comments.first?.date != nil)
    #expect(state.merge == .ready(nil))
    #expect(state.canEditLabels && state.canComment && !state.canEditReviewers)

    let readOnly = PullRequestDetailAdapter.content(
      detail: .loaded(info(detail())), files: nil, canEdit: false)
    guard case .ready(let viewer) = readOnly else { return }
    #expect(viewer.merge == nil && !viewer.canEditLabels && !viewer.canComment)
  }

  @Test func theMergeAreaFollowsTheMergeState() {
    #expect(PullRequestDetailAdapter.merge(detail(autoMerge: "SQUASH")) == .autoMerge)
    #expect(
      PullRequestDetailAdapter.merge(detail(mergeState: "DIRTY"))
        == .blocked("Resolve conflicts first."))
    #expect(
      PullRequestDetailAdapter.merge(detail(mergeState: nil))
        == .checking("Checking whether it can merge\u{2026}"))
    guard case .ready(let caveat?) = PullRequestDetailAdapter.merge(detail(mergeState: "UNSTABLE"))
    else {
      Issue.record("an unstable PR still merges, with a caveat")
      return
    }
    #expect(caveat.contains("aren\u{2019}t required"))
  }

  @Test func checksGroupByBucketWithFailuresFirst() {
    let checks = PullRequestChecks(
      passing: 2, failing: 1, pending: 0, cancelled: 0, skipped: 0, total: 3, partial: true,
      runs: [
        CheckRun(name: "lint", bucket: .failing, url: "https://ci/1"),
        CheckRun(name: "test", bucket: .passing, url: nil),
      ])
    guard
      case .ready(let state) = PullRequestDetailAdapter.content(
        detail: .loaded(info(detail(checks: checks))), files: nil, canEdit: true)
    else { return }
    #expect(state.checks.map(\.bucket) == [.failed, .passed])
    #expect(state.checks.first?.runs.first?.url?.absoluteString == "https://ci/1")
    #expect(state.checksNote?.hasPrefix("Some checks are unavailable") == true)
  }

  @Test func noPullRequestExplainsWhy() {
    let content = PullRequestDetailAdapter.content(
      detail: .loaded(info(nil, availability: .noCli(cli: "gh"))), files: nil, canEdit: true)
    guard case .unavailable(let title, _, _) = content else {
      Issue.record("expected an explanation, got \(content)")
      return
    }
    #expect(title == "GitHub CLI not found")
  }

  @Test func reviewerIdsRoundTripAndMergeMethodsLeadWithTheDefault() {
    let target = PullRequestDetailAdapter.reviewerTarget("team:core")
    #expect(target == ReviewerTarget(login: "core", kind: .team))
    #expect(PullRequestDetailAdapter.reviewerTarget("nobody") == nil)
    let chips = PullRequestPanelSlots.mergeMethods(
      MergeOptions(methods: [.merge, .squash], defaultMethod: .squash))
    #expect(chips.map(\.id) == ["squash", "merge"])
    #expect(PullRequestPanelSlots.mergeMethod("rebase") == .rebase)
  }

  @Test func commitsAndForcePushesJoinTheFeedAndEditorsCanEditTheText() throws {
    var pullRequest = detail()
    pullRequest.timelineEvents = [
      PullRequestTimelineEvent(
        id: "e1", kind: .forcePush(previousSha: "1111111aaa"), author: nil,
        createdAt: "2026-01-01T00:00:00Z", url: nil, sha: "2222222bbb", message: nil),
      PullRequestTimelineEvent(
        id: "e2", kind: .commit, author: "ann", createdAt: "2026-01-03T00:00:00Z",
        url: "https://c/2", sha: "3333333", message: "Fix it"),
    ]
    pullRequest.timelinePartial = true
    let content = PullRequestDetailAdapter.content(
      detail: .loaded(
        info(pullRequest, capabilities: prCapabilities(details: true, attachments: true))),
      files: nil, canEdit: true)
    guard case .ready(let state) = content else {
      Issue.record("expected the detail, got \(content)")
      return
    }
    #expect(state.timeline.map(\.author) == ["unknown", "ann"])
    #expect(state.timeline.first?.kind == .forcePush(previousSHA: "1111111aaa"))
    #expect(state.timelinePartial)
    // The comment, from 2026-01-02, sits between the push and the commit.
    #expect(state.feed.map(\.id) == ["event-e1", "comment-https://c", "event-e2"])
    #expect(state.canEditDetails && state.canAttach)

    let viewer = PullRequestDetailAdapter.content(
      detail: .loaded(info(pullRequest, capabilities: prCapabilities(details: true))), files: nil,
      canEdit: false)
    guard case .ready(let read) = viewer else { return }
    #expect(!read.canEditDetails && !read.canAttach)
  }

  @Test func theStoredPullRequestSaysWhenItWasReadAndWhatLoadsTheRest() {
    var pullRequest = SessionPullRequest(
      url: url, host: "github.com", repository: "o/r", number: 7, title: "  ",
      relationship: "created", providerName: "GitHub", status: .draft,
      stateCheckedAt: 1_700_000_000)
    var stored = PullRequestDetailAdapter.stored(pullRequest)
    #expect(stored.title == "o/r #7", "a blank title reads as the repository and number")
    #expect(stored.status == .draft)
    #expect(stored.hint.hasPrefix("Last sync time: "))
    #expect(stored.hint.hasSuffix("please reconnect the session\u{2019}s host."))
    pullRequest.stateCheckedAt = nil
    pullRequest.title = "Fix login"
    stored = PullRequestDetailAdapter.stored(pullRequest)
    #expect(stored.title == "Fix login")
    #expect(stored.hint == "To load the PR details, please reconnect the session\u{2019}s host.")
  }

  @Test func aGitLabMergeRequestKeepsItsNumberPrefixInRowsTheChipAndTheStoredDetail() {
    var request = SessionPullRequest(
      url: url, host: "gitlab.example.com", repository: "o/r", number: 7, title: nil,
      relationship: "created", providerName: "GitLab", numberPrefix: "!", status: .open,
      stateCheckedAt: nil)
    let row = PullRequestAdapter.summary(request)
    #expect(row.numberLabel == "!7")
    #expect(row.title == "Pull request !7")
    #expect(PullRequestDetailAdapter.stored(request).numberLabel == "!7")
    #expect(PullRequestDetailAdapter.stored(request).title == "o/r !7")
    request.numberPrefix = "#"
    #expect(PullRequestAdapter.summary(request).numberLabel == "#7")
  }

  @Test func aLiveConditionColorsAnOpenRowButNotAMergedOne() {
    let open = SessionPullRequest(
      url: url, host: "github.com", repository: "o/r", number: 7, title: "Fix",
      relationship: "created", providerName: nil, status: .open, stateCheckedAt: nil)
    #expect(PullRequestAdapter.summary(open, live: .checksFailing).status == .failing)
    var merged = open
    merged.status = .merged
    #expect(PullRequestAdapter.summary(merged, live: .checksFailing).status == .merged)
  }
}

/// Why a session's Pull Requests tab has nothing to show, and what the person can do about it.
@MainActor
struct PullRequestUnavailableTests {
  private func shown(_ info: PullRequestInfo) throws -> (title: String, message: String) {
    let content = PullRequestDetailAdapter.content(
      detail: .loaded(info), files: nil, canEdit: true)
    guard case .unavailable(let title, let message, _) = content else {
      throw PullRequestError.notUnavailable("\(content)")
    }
    return (title, message)
  }

  private enum PullRequestError: Error {
    case notUnavailable(String)
  }

  @Test func anUnnamedProviderIsStillSaidInWords() throws {
    var bare = info(nil, availability: .repositoryUnresolved(hint: nil))
    bare.providerName = nil
    #expect(try shown(bare).message.contains("the git provider"))
  }

  @Test func aMergeStateNobodyKnowsSaysSo() {
    #expect(
      PullRequestDetailAdapter.merge(detail(mergeState: "WEIRD"))
        == .blocked("GitHub reports that it can\u{2019}t merge yet."))
  }

  @Test func aCommentWithoutAnAuthorOrAddressStillShows() {
    var pullRequest = detail()
    pullRequest.comments = [
      PullRequestComment(author: nil, body: "x", createdAt: nil, url: nil)
    ]
    let content = PullRequestDetailAdapter.content(
      detail: .loaded(info(pullRequest)), files: nil, canEdit: false)
    guard case .ready(let state) = content else {
      Issue.record("expected the detail, got \(content)")
      return
    }
    #expect(state.comments.first?.author == "Unknown")
    #expect(state.comments.first?.id == "0")
  }

  @Test func eachReasonSaysWhatToDo() throws {
    #expect(try shown(info(nil, availability: .notAGitRepository)).title == "Not a git repository")
    #expect(try shown(info(nil, availability: .hostOutdated)).title == "Update your host")
    #expect(
      try shown(info(nil, availability: .unsupportedRemote(remoteHost: "git.example"))).message
        .contains("git.example"))
    #expect(
      try shown(info(nil, availability: .unsupportedRemote(remoteHost: nil))).title
        == "No supported remote")
    #expect(
      try shown(info(nil, availability: .repositoryUnresolved(hint: "Run gh auth login"))).message
        == "Run gh auth login")
    #expect(
      try shown(info(nil, availability: .repositoryUnresolved(hint: nil))).message
        == "Sign in to GitHub on the host.")
    #expect(try shown(info(nil, availability: .unavailable)).title == "Pull request unavailable")
  }

  @Test func aHostsWarningExplainsAReadThatFailed() throws {
    var warned = info(nil, availability: .unavailable)
    warned.warnings = ["GitHub says no"]
    #expect(try shown(warned).message == "GitHub says no")
  }
}
