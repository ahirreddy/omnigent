import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let otherURL = "https://github.com/o/r/pull/8"
nonisolated private let github = "/v1/sessions/conv_a/resources/github"

nonisolated private let oneLinked = #"""
  {"object":"list","data":[{"url":"https://github.com/o/r/pull/7","host":"github.com",
   "repository":"o/r","number":7,"title":"Fix","relationship":"created","state":"OPEN"}],
   "has_more":false,"synced":true}
  """#

nonisolated private let nothingSelected =
  #"{"object":"session.github.info","available":true,"tracking_available":true,"prs":[]}"#

nonisolated private func info(head: String? = "abc") -> String {
  let headField = head.map { #""head_sha":"\#($0)","# } ?? ""
  return #"""
    {"object":"session.github.info","available":true,"branch":"fix",
     "repo":{"name_with_owner":"o/r"},"auth":{"authenticated":true},
     "capabilities":{"label_editing":true,"merging":true},"selected_pr_url":"\#(prURL)",
     "tracking_available":true,"prs":[],
     "pr":{"number":7,"title":"Fix","state":"OPEN","url":"\#(prURL)",\#(headField)
           "labels":[],"reviewers":[],"comments":[],"merge_state_status":"CLEAN"}}
    """#
}

@MainActor
private func panel(_ head: String? = "abc") async throws -> (RouteServer, SessionPanelStore) {
  let server = RouteServer()
  server.route(
    "/v1/info",
    .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
  server.route("/v1/sessions/conv_a/pull-requests", .json(oneLinked))
  server.route(github, .json(info(head: head)))
  server.route("\(github)/diff", .json(#"{"object":"session.github.pr_diff","patch":""}"#))
  let connection = try await connectedStore(server)
  return (server, try #require(connection.makePanelStore("conv_a")))
}

@MainActor
private func opened(_ head: String? = "abc") async throws -> (RouteServer, SessionPanelStore) {
  let (server, store) = try await panel(head)
  await store.showPullRequest(prURL)
  #expect(store.openPullRequest == prURL)
  return (server, store)
}

private func isFailed<Value>(_ load: CreationLoad<Value>) -> Bool {
  if case .failed = load { return true }
  return false
}

private func arrived(_ gate: RouteGate) async throws {
  try await eventually("the request") { gate.arrivals > 0 }
}

private func sentBody(_ server: RouteServer, _ route: String) throws -> [String: Any] {
  let request = try #require(server.requests(to: "\(github)/\(route)", method: "POST").last)
  return try server.body(of: request)
}

/// What the panel does with each change to the session's pull requests.
@MainActor
@Suite("Linking and picking pull requests", .timeLimit(.minutes(1)))
struct PullRequestEditTests {
  @Test("Linking shows the linked pull request; a refusal says why")
  func links() async throws {
    let (server, store) = try await panel()
    server.fail("\(github)/prs", method: "POST", status: 422, detail: "not a PR")
    #expect(await !store.linkPullRequest(prURL))
    #expect(store.editError != nil)
    #expect(store.openPullRequest == nil)

    server.route("\(github)/prs", method: "POST", .json(info()))
    #expect(await store.linkPullRequest(prURL))
    #expect(store.editError == nil, "the next change clears the last failure")
    #expect(store.openPullRequest == prURL)
    #expect(store.pendingEdit == nil)
  }

  @Test("A link with nothing selected leaves the list showing")
  func linkWithoutSelection() async throws {
    let (server, store) = try await panel()
    server.route("\(github)/prs", method: "POST", .json(nothingSelected))
    #expect(await store.linkPullRequest(prURL))
    #expect(store.openPullRequest == nil)
  }

  @Test("Unlinking the open pull request goes back to the list; another stays open")
  func unlinks() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/prs", method: "POST")
    await store.unlinkPullRequest(prURL)
    #expect(store.openPullRequest == prURL, "a refused unlink keeps it open")
    #expect(store.editError != nil)

    server.route("\(github)/prs", method: "POST", .json(nothingSelected))
    await store.unlinkPullRequest(otherURL)
    #expect(store.openPullRequest == prURL)
    await store.unlinkPullRequest(prURL)
    #expect(store.openPullRequest == nil)
  }

  // MARK: Reads for the pickers

  @Test("The label picker reads once per pull request and shows a failure")
  func repositoryLabels() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/labels", method: "GET")
    await store.loadRepositoryLabels()
    #expect(isFailed(store.repositoryLabels))

    server.route(
      "\(github)/labels", method: "GET",
      .json(#"{"data":[{"name":"bug","color":"d73a4a"}],"has_more":false}"#))
    await store.loadRepositoryLabels()
    #expect(store.repositoryLabels.value?.labels.map(\.name) == ["bug"])
    let reads = server.requests(to: "\(github)/labels").count
    await store.loadRepositoryLabels()
    #expect(server.requests(to: "\(github)/labels").count == reads)
  }

  @Test("The reviewer picker reads once per pull request and shows a failure")
  func reviewCandidates() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/reviewers", method: "GET")
    await store.loadReviewCandidates()
    #expect(isFailed(store.reviewCandidates))

    server.route(
      "\(github)/reviewers", method: "GET",
      .json(#"{"data":[{"login":"ann","kind":"user","name":"Ann"}],"has_more":false}"#))
    await store.loadReviewCandidates()
    #expect(store.reviewCandidates.value?.candidates.map(\.login) == ["ann"])
    let reads = server.requests(to: "\(github)/reviewers").count
    await store.loadReviewCandidates()
    #expect(server.requests(to: "\(github)/reviewers").count == reads)
  }

  @Test("The merge menu reads once per pull request and shows a failure")
  func mergeOptions() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/merge-options", method: "GET")
    await store.loadMergeOptions()
    #expect(isFailed(store.mergeOptions))

    server.route(
      "\(github)/merge-options", method: "GET",
      .json(#"{"methods":["squash","merge"],"default":"squash"}"#))
    await store.loadMergeOptions()
    #expect(store.mergeOptions.value?.methods == [.squash, .merge])
    let reads = server.requests(to: "\(github)/merge-options").count
    await store.loadMergeOptions()
    #expect(server.requests(to: "\(github)/merge-options").count == reads)
  }

  @Test("Nothing is read or written with no pull request open")
  func nothingOpen() async throws {
    let (server, store) = try await panel()
    let target = ReviewerTarget(login: "ann", kind: .user)
    await store.loadRepositoryLabels()
    await store.loadReviewCandidates()
    await store.loadMergeOptions()
    await store.setLabel("bug", added: true)
    await store.setReviewer(target, requested: true)
    await store.disableAutoMerge()
    #expect(await !store.mergePullRequest(.squash))
    #expect(await !store.postComment("hi"))
    #expect(store.repositoryLabels == .idle)
    #expect(store.reviewCandidates == .idle)
    #expect(store.mergeOptions == .idle)
    #expect(server.requests(to: "\(github)/labels").isEmpty)
    #expect(server.requests(to: "\(github)/merge").isEmpty)
  }

  @Test("A picker read that returns after another pull request opened is dropped")
  func stalePickerRead() async throws {
    let (server, store) = try await opened()
    let labels = server.hold("\(github)/labels", method: "GET")
    let candidates = server.hold("\(github)/reviewers", method: "GET")
    let options = server.hold("\(github)/merge-options", method: "GET")
    async let labelRead: Void = store.loadRepositoryLabels()
    async let candidateRead: Void = store.loadReviewCandidates()
    async let optionsRead: Void = store.loadMergeOptions()
    try await arrived(labels)
    try await arrived(candidates)
    try await arrived(options)

    store.showPullRequestList()
    server.route(
      "\(github)/labels", method: "GET", .json(#"{"data":[{"name":"stale"}],"has_more":false}"#))
    server.route(
      "\(github)/reviewers", method: "GET",
      .json(#"{"data":[{"login":"stale","kind":"user"}],"has_more":false}"#))
    server.route(
      "\(github)/merge-options", method: "GET", .json(#"{"methods":["merge"],"default":"merge"}"#))
    labels.release()
    candidates.release()
    options.release()
    _ = await (labelRead, candidateRead, optionsRead)

    #expect(store.repositoryLabels.value == nil)
    #expect(store.reviewCandidates.value == nil)
    #expect(store.mergeOptions.value == nil)
  }
}

/// Changes to the pull request on screen.
@MainActor
@Suite("Pull request edits", .timeLimit(.minutes(1)))
struct PullRequestChangeTests {
  @Test("Adding and removing a label sends only that label and shows the provider's answer")
  func setsLabels() async throws {
    let (server, store) = try await opened()
    server.route(
      "\(github)/labels", method: "POST", .json(#"{"labels":[{"name":"bug","color":"d73a4a"}]}"#))
    await store.setLabel("bug", added: true)
    #expect(store.detail.value?.pullRequest?.labels?.map(\.name) == ["bug"])
    #expect(try sentBody(server, "labels")["add"] as? [String] == ["bug"])

    server.route("\(github)/labels", method: "POST", .json(#"{"labels":[]}"#))
    await store.setLabel("bug", added: false)
    #expect(store.detail.value?.pullRequest?.labels?.isEmpty == true)
    #expect(try sentBody(server, "labels")["remove"] as? [String] == ["bug"])

    server.fail("\(github)/labels", method: "POST")
    await store.setLabel("docs", added: true)
    #expect(store.editError != nil)
    #expect(store.detail.value?.pullRequest?.labels?.isEmpty == true, "a refusal changes nothing")
    store.dismissEditError()
    store.dismissEditError()
    #expect(store.editError == nil)
  }

  @Test("Requesting and withdrawing a review shows the provider's answer")
  func setsReviewers() async throws {
    let (server, store) = try await opened()
    let ann = ReviewerTarget(login: "ann", kind: .user)
    server.route(
      "\(github)/reviewers", method: "POST",
      .json(#"{"reviewers":[{"login":"ann","kind":"user","state":"PENDING"}]}"#))
    await store.setReviewer(ann, requested: true)
    #expect(store.detail.value?.pullRequest?.reviewers?.map(\.login) == ["ann"])

    server.route("\(github)/reviewers", method: "POST", .json(#"{"reviewers":[]}"#))
    await store.setReviewer(ann, requested: false)
    #expect(store.detail.value?.pullRequest?.reviewers?.isEmpty == true)
    #expect((try sentBody(server, "reviewers")["remove"] as? [Any])?.count == 1)

    server.fail("\(github)/reviewers", method: "POST")
    await store.setReviewer(ann, requested: true)
    #expect(store.editError != nil)
  }

  @Test("A change that returns after another pull request opened doesn't touch its detail")
  func staleChange() async throws {
    let (server, store) = try await opened()
    let labels = server.hold("\(github)/labels", method: "POST")
    async let change: Void = store.setLabel("bug", added: true)
    try await arrived(labels)
    store.showPullRequestList()
    server.route("\(github)/labels", method: "POST", .json(#"{"labels":[{"name":"bug"}]}"#))
    labels.release()
    await change
    #expect(store.detail == .idle)
  }

  @Test("Only one change runs at a time")
  func oneChangeAtATime() async throws {
    let (server, store) = try await opened()
    let labels = server.hold("\(github)/labels", method: "POST")
    async let first: Void = store.setLabel("bug", added: true)
    try await arrived(labels)
    #expect(store.pendingEdit == .labels)
    #expect(await !store.postComment("too soon"))
    #expect(server.requests(to: "\(github)/comments").isEmpty)
    server.route("\(github)/labels", method: "POST", .json(#"{"labels":[]}"#))
    labels.release()
    await first
    #expect(store.pendingEdit == nil)
  }

  @Test("Merging sends the head on screen, then re-reads; a refusal keeps the panel as it was")
  func merges() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/merge", method: "POST", status: 409)
    #expect(await !store.mergePullRequest(.squash))
    #expect(store.editError != nil)

    server.route("\(github)/merge", method: "POST", .json("{}"))
    let reads = server.requests(to: github).count
    #expect(await store.mergePullRequest(.merge))
    let body = try sentBody(server, "merge")
    #expect(body["expected_head"] as? String == "abc")
    #expect(body["merge_method"] as? String == "merge")
    #expect(server.requests(to: github).count > reads, "the detail is read again")
  }

  @Test("A merge can't start before the head is known")
  func mergeWithoutHead() async throws {
    let (server, store) = try await opened(nil)
    #expect(await !store.mergePullRequest(.merge))
    #expect(server.requests(to: "\(github)/merge").isEmpty)
  }

  @Test("Turning off auto-merge re-reads the pull request; a refusal says why")
  func autoMerge() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/disable-auto-merge", method: "POST")
    let reads = server.requests(to: github).count
    await store.disableAutoMerge()
    #expect(store.editError != nil)
    #expect(server.requests(to: github).count == reads)

    server.route("\(github)/disable-auto-merge", method: "POST", .json("{}"))
    await store.disableAutoMerge()
    #expect(store.editError == nil)
    #expect(server.requests(to: github).count > reads)
  }

  @Test("A posted comment joins the thread; a refused one doesn't, and keeps the reason")
  func comments() async throws {
    let (server, store) = try await opened()
    server.fail("\(github)/comments", method: "POST")
    #expect(await !store.postComment("hi"))
    #expect(store.editError != nil)
    #expect(store.detail.value?.pullRequest?.comments.isEmpty == true)

    server.route(
      "\(github)/comments", method: "POST",
      .json(#"{"comment":{"author":"me","body":"hi","url":"c"}}"#))
    #expect(await store.postComment("hi"))
    #expect(store.detail.value?.pullRequest?.comments.map(\.body) == ["hi"])
  }

  @Test("A comment posted before another pull request opened isn't added to its thread")
  func staleComment() async throws {
    let (server, store) = try await opened()
    let comments = server.hold("\(github)/comments", method: "POST")
    async let posted = store.postComment("hi")
    try await arrived(comments)
    store.showPullRequestList()
    server.route(
      "\(github)/comments", method: "POST",
      .json(#"{"comment":{"author":"me","body":"hi","url":"c"}}"#))
    comments.release()
    #expect(await posted, "the comment was still posted")
    #expect(store.detail == .idle)
  }
}
