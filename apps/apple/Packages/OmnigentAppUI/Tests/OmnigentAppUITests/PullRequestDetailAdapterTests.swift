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
    baseRef: "main", headRef: "fix", headSha: "abc", body: "Body",
    checks: checks
      ?? PullRequestChecks(
        passing: 0, failing: 0, pending: 0, cancelled: 0, skipped: 0, total: 0, partial: false,
        runs: []),
    checksSupported: checksSupported,
    comments: [
      PullRequestComment(
        author: "bob", body: "LGTM", createdAt: "2026-01-02T03:04:05Z", url: "https://c")
    ],
    commentsPartial: false,
    reviewers: [
      PullRequestReviewer(login: "Core", kind: .team, state: .pending),
      PullRequestReviewer(login: "bob", kind: .user, state: .approved),
    ],
    labels: [PullRequestLabel(name: "bug", color: "d73a4a", description: "Broken")],
    mergeStateStatus: mergeState, reportsMergeState: true, autoMergeMethod: autoMerge)
}

private func info(
  _ pullRequest: PullRequestDetail?, availability: PullRequestAvailability = .ready,
  capabilities: PullRequestCapabilities = PullRequestCapabilities(
    labelEditing: true, merging: true, commentPosting: true, reviewerEditing: false)
) -> PullRequestInfo {
  PullRequestInfo(
    availability: availability, providerName: "GitHub", numberPrefix: "#", branch: "fix",
    repository: "o/r", baseRef: "main", selectedUrl: url, trackingAvailable: true, linked: [],
    warnings: [], capabilities: capabilities, pullRequest: pullRequest)
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
    #expect(title == "gh not found")
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
