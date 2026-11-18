import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

private let prURL = "https://github.com/o/r/pull/7"
private let path = WorkspaceSamples.libDiff.path

private func thread(
  _ id: String, path: String = path, side: String = "RIGHT", line: String = "1",
  file: Bool = false, outdated: Bool = false, resolved: Bool = false
) -> String {
  #"""
  {"id":"\#(id)","path":"\#(path)","side":"\#(side)","line":\#(line),"original_line":2,
   "subject_type":"\#(file ? "FILE" : "LINE")","resolved":\#(resolved),"outdated":\#(outdated),
   "can_reply":true,"diff_hunk":"@@ -1,2 +1,2 @@",
   "comments":{"data":[{"id":"c-\#(id)","author":"ann","body":"Look","created_at":null}],
               "has_more":false,"next_cursor":null}}
  """#
}

/// The open PR's threads placed on its diff as the web places them.
@MainActor
@Suite("Review threads on the diff")
struct ReviewThreadsAdapterTests {
  private func panel(
    threads: [String], head: String = "head1", creation: Bool = true
  ) async throws -> SessionPanelStore {
    let info = #"""
      {"object":"session.github.info","available":true,"repo":{"name_with_owner":"o/r"},
       "auth":{"authenticated":true},"selected_pr_url":"\#(prURL)",
       "capabilities":{"review_threads":true,"review_thread_replies":true,
                       "review_thread_creation":\#(creation)},
       "pr":{"number":7,"title":"Fix","state":"OPEN","url":"\#(prURL)","head_sha":"head1",
             "base_sha":"base1"}}
      """#
    let page = #"""
      {"data":[\#(threads.joined(separator: ","))],"has_more":false,"next_cursor":null,
       "head_sha":"\#(head)","base_sha":"base1"}
      """#
    let core = try await ConversationFixtures.core(routes: [
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      "/v1/sessions/conv/resources/github": .json(info),
      "/v1/sessions/conv/resources/github/diff": .json(
        #"{"object":"session.github.pr_diff","patch":""}"#),
      "/v1/sessions/conv/resources/github/review-threads": .json(page),
    ])
    let panel = SessionPanelStore(sessionID: "conv", core: core)
    await panel.showPullRequest(prURL)
    await panel.loadReviewThreads()
    return panel
  }

  @Test("A thread on a shown line sits under it; outdated, file and unshown ones under the file")
  func placesThreads() async throws {
    let store = try await panel(threads: [
      thread("on-line"), thread("outdated", side: "LEFT", line: "null", outdated: true),
      thread("on-file", line: "null", file: true), thread("off-hunk", line: "999"),
      thread("elsewhere", path: "other.rs"),
    ])
    let annotations = ReviewThreadsAdapter.annotations(
      store, files: [WorkspaceSamples.libDiff], canEdit: true)
    #expect(Array(annotations.lines.keys) == [DiffLineAnchor(path: path, side: .new, line: 1)])
    #expect(Array(annotations.files.keys) == [path])
    #expect(annotations.select != nil)

    let page = try #require(store.reviewThreads.value)
    let outdated = ReviewThreadsAdapter.threadState(
      try #require(page.threads.first { $0.id == "outdated" }), reply: "draft", canEdit: true,
      caps: try #require(store.detail.value?.capabilities))
    #expect(outdated.lineLabel == "Old line 2", "an outdated thread shows where it was written")
    #expect(outdated.outdated && outdated.canReply && outdated.reply == "draft")
  }

  @Test("Threads read at another revision all sit under their file")
  func otherRevision() async throws {
    let store = try await panel(threads: [thread("on-line")], head: "older")
    let annotations = ReviewThreadsAdapter.annotations(
      store, files: [WorkspaceSamples.libDiff], canEdit: true)
    #expect(annotations.lines.isEmpty)
    #expect(annotations.files[path] != nil)
  }

  @Test("The new thread shows under its last line; lines can be chosen only by an editor")
  func newThread() async throws {
    let store = try await panel(threads: [])
    store.selectReviewLines(ReviewThreadDraft(path: path, side: .left, start: 1, end: 1))
    let annotations = ReviewThreadsAdapter.annotations(
      store, files: [WorkspaceSamples.libDiff], canEdit: true)
    #expect(annotations.lines[DiffLineAnchor(path: path, side: .old, line: 1)] != nil)
    #expect(annotations.selection?.side == .old)

    let viewer = ReviewThreadsAdapter.annotations(
      store, files: [WorkspaceSamples.libDiff], canEdit: false)
    #expect(viewer.select == nil)
    let readOnlyHost = try await panel(threads: [], creation: false)
    let none = ReviewThreadsAdapter.annotations(
      readOnlyHost, files: [WorkspaceSamples.libDiff], canEdit: true)
    #expect(none.select == nil)
  }

  @Test("Line labels say the side and the range, or that it's about the file")
  func labels() {
    typealias State = PullRequestReviewThreadState
    #expect(State.lineLabel(old: false, start: nil, end: 12) == "New line 12")
    #expect(State.lineLabel(old: true, start: 2, end: 4) == "Old lines 2\u{2013}4")
    #expect(State.lineLabel(old: false, start: 4, end: 4) == "New line 4")
    #expect(State.lineLabel(old: false, start: nil, end: nil) == "File conversation")
  }
}
