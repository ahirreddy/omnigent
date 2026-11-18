import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let github = "/v1/sessions/conv_a/resources/github"
nonisolated private let comments = "/v1/sessions/conv_a/comments"

nonisolated private func info(head: String = "head1", creation: Bool = false) -> String {
  #"""
  {"object":"session.github.info","available":true,"repo":{"name_with_owner":"o/r"},
   "auth":{"authenticated":true},"capabilities":{"review_thread_creation":\#(creation)},
   "selected_pr_url":"\#(prURL)","tracking_available":true,"prs":[],
   "pr":{"number":7,"title":"Fix","state":"OPEN","url":"\#(prURL)","head_sha":"\#(head)",
         "base_sha":"base1"}}
  """#
}

/// `asdict(Comment)` of a local comment on `src/a.txt`.
nonisolated private func comment(_ id: String, line: Int = 3, head: String = "head1") -> String {
  #"""
  {"id":"\#(id)","conversation_id":"conv_a","path":"src/a.txt","start_index":0,"end_index":0,
   "body":"Rename this","status":"draft","created_at":10,"updated_at":10000000,
   "anchor_content":null,"created_by":null,
   "anchor_metadata":{"pr_url":"\#(prURL)","side":"RIGHT","line":\#(line),"start_line":null,
                      "head_sha":"\#(head)","base_sha":"base1"}}
  """#
}

@MainActor
private func opened(anchors: Bool = true, creation: Bool = false) async throws
  -> (RouteServer, SessionPanelStore)
{
  let server = RouteServer()
  server.route(
    "/v1/info",
    .json(
      #"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true,"comment_anchor_metadata":\#(anchors)}"#
    ))
  server.route(github, .json(info(creation: creation)))
  server.route("\(github)/changes", .json(#"{"object":"list","data":[],"has_more":false}"#))
  server.route(
    "\(github)/diff",
    .json(#"{"object":"session.github.pr_diff","patch":"","head_sha":"head1","base_sha":"base1"}"#))
  server.route(
    comments, method: "GET",
    .json(#"{"comments":[\#(comment("c1")),\#(comment("old", head: "head0"))],"next_cursor":null}"#)
  )
  let connection = try await connectedStore(server)
  let defaults = try #require(UserDefaults(suiteName: "pr-local-\(UUID().uuidString)"))
  let store = SessionPanelStore(
    sessionID: "conv_a", core: try #require(connection.core),
    viewedMarks: PullRequestViewedMarks(defaults: defaults), preferences: defaults)
  await store.loadFeatures()
  await store.showPullRequest(prURL)
  return (server, store)
}

/// Local review comments on the diff, for the agent, as the web's `LocalReviewComment` and
/// `ComposerLocalReviewChips` keep them.
@MainActor
@Suite("Pull request local comments", .timeLimit(.minutes(1)))
struct PullRequestLocalCommentsTests {
  @Test("The session's comments on the PR read with their place; an older server offers none")
  func reads() async throws {
    let (server, store) = try await opened()
    await store.loadLocalComments()
    #expect(store.openLocalComments.map(\.id) == ["c1", "old"])
    let read = try #require(server.requests(to: comments, method: "GET").last)
    #expect(read.url.contains("include_pr_comments=true"))
    let earlier = try #require(store.openLocalComments.last)
    #expect(store.isEarlier(earlier), "written at another head")
    #expect(!store.isEarlier(try #require(store.openLocalComments.first)))

    let (plain, without) = try await opened(anchors: false)
    await without.loadLocalComments()
    #expect(without.localComments == .idle)
    #expect(plain.requests(to: comments).isEmpty)
  }

  @Test("A comment for the agent goes at the revision on screen and onto the composer")
  func posts() async throws {
    let (server, store) = try await opened()
    var attached: [String] = []
    store.attachReviewComment = { attached.append($0.id) }
    server.route(comments, method: "POST", .json(comment("c9", line: 5)))
    store.selectReviewLines(
      ReviewThreadDraft(path: "src/a.txt", side: .right, start: 5, end: 5), destination: .agent)
    #expect(store.newReviewThread?.destination == .agent)
    store.setNewReviewThreadBody("Rename this")
    #expect(await store.startReviewThread())
    #expect(attached == ["c9"])
    #expect(store.newReviewThread == nil)
    let sent = try server.body(of: try #require(server.requests(to: comments, method: "POST").last))
    let anchor = try #require(sent["anchor_metadata"] as? [String: Any])
    #expect(anchor["pr_url"] as? String == prURL && anchor["line"] as? Int == 5)
    #expect(anchor["head_sha"] as? String == "head1" && anchor["side"] as? String == "RIGHT")
    #expect(anchor["start_line"] is NSNull, "one line has no range")
  }

  @Test("The destination is remembered for the next draft; without anchors it is the provider")
  func destination() async throws {
    let (_, store) = try await opened(creation: true)
    store.selectReviewLines(ReviewThreadDraft(path: "src/a.txt", side: .right, start: 1, end: 1))
    #expect(store.newReviewThread?.destination == .github)
    store.setNewReviewThreadDestination(.agent)
    store.cancelNewReviewThread()
    store.selectReviewLines(ReviewThreadDraft(path: "src/a.txt", side: .left, start: 2, end: 2))
    #expect(store.newReviewThread?.destination == .agent)

    let (_, plain) = try await opened(anchors: false, creation: true)
    await plain.loadFeatures()
    plain.selectReviewLines(ReviewThreadDraft(path: "src/a.txt", side: .right, start: 1, end: 1))
    #expect(plain.newReviewThread?.destination == .github)
  }

  @Test("A draft whose PR moved is kept but not posted until its lines are chosen again")
  func staleDraft() async throws {
    let (server, store) = try await opened()
    store.selectReviewLines(
      ReviewThreadDraft(path: "src/a.txt", side: .right, start: 1, end: 1), destination: .agent)
    store.setNewReviewThreadBody("Later")
    server.route(github, .json(info(head: "head2")))
    server.route(
      "\(github)/diff",
      .json(
        #"{"object":"session.github.pr_diff","patch":"","head_sha":"head2","base_sha":"base1"}"#))
    await store.reloadDetail()
    #expect(store.newReviewThreadIsStale)
    #expect(await !store.startReviewThread())
    #expect(store.newReviewThread?.body == "Later")
    #expect(server.requests(to: comments, method: "POST").isEmpty)
  }

  @Test("Deleting a comment takes it off the composer; a chip shows it in the Changes tab")
  func deletesAndReveals() async throws {
    let (server, store) = try await opened()
    var detached: [String] = []
    store.detachReviewComment = { detached.append($0) }
    server.route("\(comments)/c1", method: "DELETE", .json("{}"))
    #expect(await store.deleteLocalComment("c1"))
    #expect(detached == ["c1"])

    await store.loadLocalComments()
    let earlier = try #require(store.openLocalComments.first { $0.id == "old" })
    store.setPathFilter("nothing")
    await store.revealLocalComment(earlier)
    #expect(store.opensChangesTab)
    #expect(store.changesView.pathFilter.isEmpty && store.changesMode == .changes)
    #expect(store.changesView.shownEarlierComments.contains("src/a.txt"))
    if case .line(let path, let side, let line) = store.changesView.scroll?.target {
      #expect((path, side, line) == ("src/a.txt", .new, 3))
    } else {
      Issue.record("the diff scrolls to the comment")
    }
    store.changesTabOpened()
    #expect(!store.opensChangesTab)
  }
}

/// The composer sends attached local review comments after its text, as the web does.
@MainActor
@Suite("Composer review comments", .timeLimit(.minutes(1)))
struct ComposerReviewCommentTests {
  private func review(_ id: String) -> LocalReviewComment {
    LocalReviewComment(
      id: id, sessionId: "conv_a", path: "src/a.txt", startIndex: 0, endIndex: 0,
      body: "Rename this", status: "draft", createdAt: 10, updatedAt: 10_000_000,
      anchorContent: nil, author: nil,
      anchor: ReviewCommentAnchor(
        prUrl: prURL, side: .right, line: 3, startLine: nil, headSha: "head1",
        baseSha: "base1"))
  }

  @Test("Attached comments follow the text, alone they carry the instruction, then they clear")
  func sendsComments() async throws {
    let live = try await LiveComposer()
    live.acceptMessages()
    let composer = live.composer
    composer.attachReviewComment(review("c1"))
    composer.attachReviewComment(review("c1"))
    #expect(composer.reviewComments.count == 1, "once")
    #expect(composer.canSend, "a comment alone can be sent")
    await composer.send()
    let alone = try #require(live.postedTexts.last)
    #expect(
      alone.hasPrefix("Please address these local review comments:\n\n```local-review-comment\n"))
    #expect(composer.reviewComments.isEmpty)

    composer.attachReviewComment(review("c2"))
    composer.text = "Fix it"
    await composer.send()
    let withText = try #require(live.postedTexts.last)
    #expect(withText.hasPrefix("Fix it\n\n```local-review-comment\n{\n  \"id\": \"c2\""))
    #expect(!withText.contains("Please address"))

    composer.attachReviewComment(review("c3"))
    composer.detachReviewComment("c3")
    #expect(composer.reviewComments.isEmpty)
  }
}
