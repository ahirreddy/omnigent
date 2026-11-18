import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

nonisolated private let prURL = "https://github.com/o/r/pull/7"
nonisolated private let github = "/v1/sessions/conv_a/resources/github"

nonisolated private let info = #"""
  {"object":"session.github.info","available":true,"branch":"fix",
   "repo":{"name_with_owner":"o/r"},"auth":{"authenticated":true},
   "capabilities":{"details_editing":true,"attachment_uploads":true},
   "selected_pr_url":"https://github.com/o/r/pull/7","tracking_available":true,"prs":[],
   "pr":{"number":7,"title":"Fix","state":"OPEN","url":"https://github.com/o/r/pull/7",
         "head_sha":"abc","body":"Old","comments":[]}}
  """#

@MainActor
private func opened() async throws -> (RouteServer, SessionPanelStore) {
  let server = RouteServer()
  server.route(
    "/v1/info",
    .json(#"{"single_user":true,"accounts_enabled":false,"session_pull_requests":true}"#))
  server.route(
    "/v1/sessions/conv_a/pull-requests",
    .json(#"{"object":"list","data":[],"has_more":false,"synced":true}"#))
  server.route(github, .json(info))
  server.route("\(github)/diff", .json(#"{"object":"session.github.pr_diff","patch":""}"#))
  let connection = try await connectedStore(server)
  let store = try #require(connection.makePanelStore("conv_a"))
  await store.showPullRequest(prURL)
  return (server, store)
}

/// Editing the open pull request's title and description, and uploading attachments for it.
@MainActor
@Suite("Pull request title, description and attachments", .timeLimit(.minutes(1)))
struct PullRequestDetailsEditTests {
  @Test("A saved title or description shows the provider's text; a refusal changes nothing")
  func editsDetails() async throws {
    let (server, store) = try await opened()
    server.route(
      "\(github)/details", method: "POST",
      .json(#"{"object":"session.github.pr_details","title":"Better","body":"Old"}"#))
    #expect(await store.updateDetails(title: "Better", body: nil))
    #expect(store.detail.value?.pullRequest?.title == "Better")
    let sent = try server.body(
      of: try #require(server.requests(to: "\(github)/details", method: "POST").last))
    #expect(sent["title"] as? String == "Better" && sent["body"] == nil)

    server.fail("\(github)/details", method: "POST", status: 422, detail: "no")
    #expect(await !store.updateDetails(title: nil, body: "New"))
    #expect(store.editError?.message == "no")
    #expect(store.detail.value?.pullRequest?.body == "Old")
    #expect(store.pendingEdit == nil)
  }

  @Test("An attachment uploads beside other changes and answers its Markdown")
  func uploads() async throws {
    let (server, store) = try await opened()
    server.route(
      "\(github)/attachments", method: "POST",
      .json(
        #"{"object":"session.github.pr_attachment","url":"https://example.test/a.png","name":"a.png","content_type":"image/png"}"#
      ))
    let uploaded = await store.uploadAttachment(
      fileName: "Shot.png", contentType: "image/png", data: Data("png".utf8))
    #expect(try uploaded.get() == "![Shot](https://example.test/a.png)")
    #expect(store.pendingEdit == nil, "an upload is not a change that blocks others")

    let refused = await store.uploadAttachment(
      fileName: "notes.txt", contentType: "text/plain", data: Data("x".utf8))
    guard case .failure(let error) = refused else {
      Issue.record("a text file is not an attachment")
      return
    }
    #expect(error.message == "Only images and videos can be attached.")
    #expect(server.requests(to: "\(github)/attachments").count == 1)
  }

  @Test("Nothing uploads with no pull request open")
  func uploadsNeedAnOpenPullRequest() async throws {
    let (server, store) = try await opened()
    store.showPullRequestList()
    let result = await store.uploadAttachment(
      fileName: "a.png", contentType: "image/png", data: Data("png".utf8))
    #expect((try? result.get()) == nil)
    #expect(await !store.updateDetails(title: "x", body: nil))
    #expect(server.requests(to: "\(github)/attachments").isEmpty)
  }
}
