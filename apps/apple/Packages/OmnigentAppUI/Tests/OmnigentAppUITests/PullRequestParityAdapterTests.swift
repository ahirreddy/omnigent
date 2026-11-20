import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI

private let url = "https://github.com/o/r/pull/7"

private func capabilities(switching: Bool, mergeAs: Bool) -> PullRequestCapabilities {
  PullRequestCapabilities(
    labelEditing: false, merging: true, commentPosting: true, reviewerEditing: true,
    detailsEditing: false, attachmentUploads: false, reviewThreads: true,
    reviewThreadReplies: true, reviewThreadCreation: false, commitHistory: false,
    lineCounts: true, linkedPrDiff: true, accountSwitching: switching,
    baseRemoteSelection: false, mergeAsAccount: mergeAs)
}

private func pullRequest() -> PullRequestDetail {
  PullRequestDetail(
    number: 7, title: "Fix", url: url, status: .open, condition: .ready, author: "ann",
    baseRef: "main", headRef: "fix", headSha: "abc", baseSha: "base", body: nil,
    checks: PullRequestChecks(
      passing: 0, failing: 0, pending: 0, cancelled: 0, skipped: 0, total: 0, partial: false,
      runs: []),
    checksSupported: true, comments: [], commentsPartial: false, timelineEvents: [],
    timelinePartial: false,
    reviewers: [
      PullRequestReviewer(login: "Bob", kind: .user, state: .pending),
      PullRequestReviewer(login: "cy", kind: .user, state: .approved),
    ],
    labels: nil, mergeStateStatus: "CLEAN", reportsMergeState: true, autoMergeMethod: nil)
}

private func info(
  _ pullRequest: PullRequestDetail?, availability: PullRequestAvailability = .ready,
  provider: String? = "github", switching: Bool = true, mergeAs: Bool = true
) -> PullRequestInfo {
  PullRequestInfo(
    availability: availability, providerName: "GitHub", numberPrefix: "#", branch: "fix",
    repository: "o/r", baseRef: "main", selectedUrl: url, trackingAvailable: true, linked: [],
    warnings: [], capabilities: capabilities(switching: switching, mergeAs: mergeAs),
    pullRequest: pullRequest, polling: pullRequestPollingWithoutInfo(), provider: provider,
    accounts: [
      PullRequestAccount(login: "ann", active: true),
      PullRequestAccount(login: "bot", active: false),
    ],
    selectedAccount: "bot")
}

private func comment(_ body: String) -> ReviewComment {
  ReviewComment(id: "c", author: "ann", body: body, createdAt: nil, url: nil, minimized: false)
}

private func thread(
  line: UInt64?, start: UInt64? = nil, outdated: Bool = false, original: UInt64? = nil,
  hunk: String = "", body: String = "```suggestion\nnew\n```"
) -> ReviewThread {
  ReviewThread(
    id: "t", path: "lib.py", side: .right, line: line, startLine: start, startSide: nil,
    originalLine: original, originalStartLine: nil, onFile: false, resolved: false,
    outdated: outdated, canReply: true, diffHunk: hunk,
    comments: ReviewCommentPage(
      comments: [comment(body)], hasMore: false, nextCursor: nil, warning: nil))
}

private func file() throws -> OmnigentWorkspaceUI.FileDiff {
  let patch = """
    diff --git a/lib.py b/lib.py
    --- a/lib.py
    +++ b/lib.py
    @@ -1,3 +1,3 @@
     one
    -two
    +TWO
     three

    """
  return WorkspaceMapping.fileDiff(try #require(try parseUnifiedDiff(patch: patch).first))
}

@MainActor
@Suite("Pull requests: accounts, reviewers, suggestions and offline rows")
struct PullRequestParityAdapterTests {
  @Test func theDetailNamesTheAccountThePendingReviewersAndTheMergeAccounts() throws {
    let content = PullRequestDetailAdapter.content(
      detail: .loaded(info(pullRequest())), files: nil, canEdit: true)
    guard case .ready(let state) = content else {
      Issue.record("expected the detail, got \(content)")
      return
    }
    #expect(state.account == "bot")
    #expect(state.author == "ann")
    #expect(state.requestedReviewers == ["user:bob"])
    #expect(state.mergeAccounts.map(\.title) == ["ann (active)", "bot"])
    #expect(state.mergeAccounts.first(where: \.selected)?.login == "bot")

    guard
      case .ready(let plain) = PullRequestDetailAdapter.content(
        detail: .loaded(info(pullRequest(), mergeAs: false)), files: nil, canEdit: true)
    else { return }
    #expect(plain.mergeAccounts.isEmpty, "the merge picks no account the host can't merge as")
  }

  @Test func accountsAreOfferedOnlyWhileTheRepositoryCantBeReached() {
    let unresolved = info(nil, availability: .repositoryUnresolved(hint: nil))
    #expect(PullRequestDetailAdapter.unresolvedAccountChoices(.loaded(unresolved)).count == 2)
    #expect(PullRequestDetailAdapter.unresolvedAccountChoices(.loaded(info(pullRequest()))).isEmpty)
    let fixed = info(nil, availability: .repositoryUnresolved(hint: nil), switching: false)
    #expect(PullRequestDetailAdapter.unresolvedAccountChoices(.loaded(fixed)).isEmpty)
  }

  @Test func whyThereIsNoPullRequestUsesTheWebsWords() {
    let remote = PullRequestDetailAdapter.content(
      detail: .loaded(info(nil, availability: .unsupportedRemote(remoteHost: "git.example.com"))),
      files: nil, canEdit: true)
    guard case .unavailable(let title, let message, _) = remote else {
      Issue.record("expected the unsupported remote, got \(remote)")
      return
    }
    #expect(title == "No supported remote")
    #expect(message.contains("`glab auth login --hostname git.example.com`"))
    #expect(message.contains("`gh auth login --hostname git.example.com`"))

    let signIn = PullRequestDetailAdapter.content(
      detail: .loaded(info(nil, availability: .repositoryUnresolved(hint: "Run glab auth login."))),
      files: nil, canEdit: true)
    guard case .unavailable(_, let github, _) = signIn else { return }
    #expect(github.contains("`gh auth status`"))
    let gitlab = PullRequestDetailAdapter.content(
      detail: .loaded(
        info(
          nil, availability: .repositoryUnresolved(hint: "Run glab auth login."), provider: "gitlab"
        )),
      files: nil, canEdit: true)
    guard case .unavailable(_, let hint, _) = gitlab else { return }
    #expect(hint == "Run glab auth login.")
  }

  @Test func aSuggestionReplacesTheLinesTheDiffShows() throws {
    let file = try file()
    let source = ReviewThreadsAdapter.suggestionSource(thread(line: 3, start: 2), file: file)
    #expect(
      source == PullRequestSuggestionSource(line: 2, lines: ["TWO", "three"], original: false))
    #expect(ReviewThreadsAdapter.lines(in: file, old: true, from: 2, to: 2) == ["two"])
    #expect(ReviewThreadsAdapter.lines(in: file, old: false, from: 2, to: 5).isEmpty)
    #expect(
      ReviewThreadsAdapter.suggestionSource(thread(line: 3, body: "Looks fine"), file: file) == nil,
      "a thread that suggests nothing reads no lines")
  }

  @Test func anOutdatedSuggestionUsesTheCommentsOwnSnippet() throws {
    let outdated = thread(
      line: nil, outdated: true, original: 2, hunk: "@@ -1,2 +1,2 @@\n a\n-b\n+B")
    let source = ReviewThreadsAdapter.suggestionSource(outdated, file: try file())
    #expect(source == PullRequestSuggestionSource(line: 2, lines: ["B"], original: true))
    #expect(
      ReviewThreadsAdapter.suggestionSource(thread(line: nil, outdated: true), file: nil) == nil)
  }

  @Test func theStoredHintSaysWhatLoadsTheDetails() {
    let stored = SessionPullRequest(
      url: url, host: "github.com", repository: "o/r", number: 7, title: "Fix",
      relationship: "created", providerName: "GitHub", numberPrefix: "#", status: .open,
      stateCheckedAt: nil, provider: "github")
    #expect(
      PullRequestAdapter.storedHint(stored, sandbox: .awake)
        == "To load the PR details, please reconnect the session\u{2019}s host.")
    #expect(
      PullRequestAdapter.storedHint(stored, sandbox: .asleep)
        == "To load the PR details, send a message to start the session\u{2019}s sandbox.")
    #expect(PullRequestAdapter.storedHint(stored, sandbox: .starting).hasPrefix("Starting"))
    #expect(PullRequestAdapter.offlineTitle(.asleep) == "Sandbox asleep")
    #expect(PullRequestAdapter.offlineTitle(.awake) == "Host offline")
  }

  @Test func theProviderWordingNamesItsRequests() {
    let gitlab = PullRequestProviderWording(name: "GitLab", requestName: "merge request")
    #expect(gitlab.linkPlaceholder == "Merge request URL")
    #expect(PullRequestProviderWording().linkPlaceholder.hasPrefix("https://github.com/"))
  }
}
