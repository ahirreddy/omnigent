import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let github = "/v1/sessions/conv_a/resources/github"
nonisolated private let threads = "\(github)/review-threads"

nonisolated private func info(reviews: Bool = true) -> String {
  #"""
  {"object":"session.github.info","available":true,"branch":"fix",
   "repo":{"name_with_owner":"o/r"},"auth":{"authenticated":true},
   "capabilities":{"review_threads":\#(reviews),"review_thread_replies":true,
                   "review_thread_creation":true},
   "selected_pr_url":"\#(prURL)","tracking_available":true,"prs":[],
   "pr":{"number":7,"title":"Fix","state":"OPEN","url":"\#(prURL)","head_sha":"head1",
         "base_sha":"base1","checks":{"passing":1,"failing":0,"pending":0,"total":1}}}
  """#
}

/// A page with one thread, its newest comment, and older ones to page in.
nonisolated private func page(body: String = "Why?", more: Bool = true) -> String {
  #"""
  {"data":[{"id":"PRRT_1","path":"a.txt","side":"RIGHT","line":1,"subject_type":"LINE",
            "resolved":false,"outdated":false,"can_reply":true,"diff_hunk":"@@ -1 +1 @@",
            "comments":{"data":[{"id":"c2","author":"ann","body":"\#(body)",
                                 "created_at":"2026-01-02T00:00:00Z","url":null}],
                        "has_more":\#(more),"next_cursor":"older"}}],
   "has_more":false,"next_cursor":null,"head_sha":"head1","base_sha":"base1"}
  """#
}

@MainActor
private func opened(
  _ timer: ManualPollTimer = ManualPollTimer(), reviews: Bool = true
) async throws -> (RouteServer, SessionPanelStore) {
  let server = RouteServer()
  server.route(
    "/v1/info",
    .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
  server.route(github, .json(info(reviews: reviews)))
  server.route("\(github)/diff", .json(#"{"object":"session.github.pr_diff","patch":""}"#))
  server.route(threads, method: "GET", .json(page()))
  let connection = try await connectedStore(server)
  let store = SessionPanelStore(
    sessionID: "conv_a", core: try #require(connection.core), pollTimer: timer)
  await store.showPullRequest(prURL)
  return (server, store)
}

/// The open PR's inline review threads: read and re-read while the Changes tab shows, paged,
/// replied to and started from lines, as the web's review thread hooks do.
@MainActor
@Suite("Pull request review threads", .timeLimit(.minutes(1)))
struct PullRequestReviewThreadsTests {
  @Test("The Changes tab reads threads every 10 seconds, keeping older comments it paged in")
  func readsAndPolls() async throws {
    let timer = ManualPollTimer()
    let (server, store) = try await opened(timer)
    let watching = Task { await store.watchReviewThreads() }
    try await eventually("the wait") { timer.waiting == [.seconds(10)] }
    #expect(store.reviewThreads.value?.threads.first?.comments.comments.map(\.id) == ["c2"])

    server.route(
      "\(threads)/PRRT_1/comments", method: "GET",
      .json(
        #"{"data":[{"id":"c1","author":"bob","body":"First","created_at":"2026-01-01T00:00:00Z"}],"has_more":false,"next_cursor":null}"#
      ))
    await store.loadOlderReviewComments("PRRT_1")
    #expect(store.reviewThreads.value?.threads.first?.comments.comments.map(\.id) == ["c1", "c2"])
    #expect(store.reviewThreads.value?.threads.first?.comments.hasMore == false)

    server.route(threads, method: "GET", .json(page(body: "Why not?")))
    let reads = server.requests(to: threads, method: "GET").count
    timer.fire()
    try await eventually("the re-read") {
      server.requests(to: threads, method: "GET").count > reads
    }
    try await eventually("the next wait") { timer.waiting == [.seconds(10)] }
    let comments = store.reviewThreads.value?.threads.first?.comments.comments ?? []
    #expect(comments.map(\.id) == ["c1", "c2"], "the paged-in comment stays")
    #expect(comments.last?.body == "Why not?")
    watching.cancel()
  }

  @Test("A host without review threads reads none; a failed first read says why")
  func gatedAndFailing() async throws {
    let (server, store) = try await opened(reviews: false)
    await store.loadReviewThreads()
    #expect(store.reviewThreads == .idle)
    #expect(server.requests(to: threads).isEmpty)

    let (failing, other) = try await opened()
    failing.fail(threads, method: "GET", status: 422, detail: "no access")
    await other.loadReviewThreads()
    #expect(other.reviewThreads.error?.message == "no access")
  }

  @Test("A reply joins its thread and clears its draft; a refused one keeps the draft")
  func replies() async throws {
    let (server, store) = try await opened()
    await store.loadReviewThreads()
    store.setReviewReply("Fixed", for: "PRRT_1")
    server.fail("\(threads)/PRRT_1/replies", method: "POST", status: 422, detail: "locked")
    #expect(await !store.replyToReviewThread("PRRT_1"))
    #expect(store.reviewReplies["PRRT_1"] == "Fixed")
    #expect(store.editError?.message == "locked")

    server.route(
      "\(threads)/PRRT_1/replies", method: "POST",
      .json(
        #"{"comment":{"id":"c3","author":"me","body":"Fixed","created_at":"2026-01-03T00:00:00Z"}}"#
      ))
    #expect(await store.replyToReviewThread("PRRT_1"))
    #expect(store.reviewReplies["PRRT_1"] == nil)
    #expect(store.reviewThreads.value?.threads.first?.comments.comments.last?.id == "c3")
  }

  @Test("A new thread goes on the chosen lines at the revision on screen")
  func startsThreads() async throws {
    let (server, store) = try await opened()
    await store.loadReviewThreads()
    store.selectReviewLines(ReviewThreadDraft(path: "a.txt", side: .right, start: 3, end: 1))
    store.setNewReviewThreadBody("Nit")
    store.selectReviewLines(ReviewThreadDraft(path: "a.txt", side: .right, start: 1, end: 2))
    #expect(store.newReviewThread?.body == "Nit", "choosing other lines keeps the text")
    server.route(
      threads, method: "POST",
      .json(
        #"{"thread":{"id":"PRRT_9","path":"a.txt","side":"RIGHT","line":2,"start_line":1,"subject_type":"LINE","resolved":false,"outdated":false,"can_reply":true,"diff_hunk":"","comments":{"data":[{"id":"c9","body":"Nit"}],"has_more":false,"next_cursor":null}}}"#
      ))
    #expect(await store.startReviewThread())
    #expect(store.newReviewThread == nil)
    #expect(store.reviewThreads.value?.threads.map(\.id) == ["PRRT_1", "PRRT_9"])
    let sent = try server.body(
      of: try #require(server.requests(to: threads, method: "POST").last))
    let anchor = try #require(sent["anchor"] as? [String: Any])
    #expect(anchor["head_sha"] as? String == "head1" && anchor["start_line"] as? Int == 1)

    store.selectReviewLines(ReviewThreadDraft(path: "a.txt", side: .left, start: 1, end: 1))
    store.showPullRequestList()
    #expect(store.newReviewThread == nil && store.reviewThreads == .idle)
  }
}
