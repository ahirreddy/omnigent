#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Inline review conversations: folding, comments, replies and a new conversation.
  @Suite("Inspector: review conversations on the diff", .serialized)
  @MainActor
  struct InspectorPullRequestReviewTests {
    final class Calls {
      var log: [String] = []
    }

    private func actions(_ calls: Calls) -> PullRequestReviewActions {
      var actions = PullRequestReviewActions()
      actions.setReply = { id, text in calls.log.append("reply text \(id) \(text)") }
      actions.reply = { calls.log.append("reply \($0)") }
      actions.loadOlder = { calls.log.append("older \($0)") }
      actions.setNewBody = { calls.log.append("new text \($0)") }
      actions.postNew = { calls.log.append("post new") }
      actions.cancelNew = { calls.log.append("cancel new") }
      return actions
    }

    private func thread(
      resolved: Bool = false, older: Bool = false, reply: String = ""
    ) -> PullRequestReviewThreadState {
      var state = PullRequestReviewThreadState(
        id: "t1", lineLabel: "New line 12",
        comments: [
          PullRequestReviewCommentRow(
            id: "c1", author: "ann", date: nil, body: "Why this?", url: nil, hidden: false),
          PullRequestReviewCommentRow(
            id: "c2", author: "bob", date: nil, body: "secret", url: nil, hidden: true),
        ])
      state.resolved = resolved
      state.outdated = resolved
      state.hasOlderComments = older
      state.canReply = true
      state.reply = reply
      return state
    }

    private func screen(
      _ threads: [PullRequestReviewThreadState], new: PullRequestNewThreadState? = nil,
      calls: Calls
    ) -> OffscreenWindow<AnyView> {
      OffscreenWindow(
        AnyView(
          PullRequestReviewThreadsView(threads: threads, newThread: new, actions: actions(calls))
            .padding()),
        width: 500, height: 500)
    }

    @Test("A conversation shows where it is, its comments, and hides what the provider hid")
    func showsComments() throws {
      let calls = Calls()
      let shown = screen([thread(older: true)], calls: calls)
      defer { shown.close() }
      for line in ["New line 12", "ann", "Why this?", "Comment hidden on GitHub.", "2+"] {
        #expect(try shown.shows(line))
      }
      #expect(try !shown.shows("secret"))
      #expect(try shown.shows("Load more replies"))
    }

    @Test("A resolved conversation starts folded and opens from its header")
    func resolvedFolds() throws {
      let calls = Calls()
      let shown = screen([thread(resolved: true)], calls: calls)
      defer { shown.close() }
      #expect(try shown.shows("Resolved"))
      #expect(try shown.shows("Outdated"))
      #expect(try !shown.shows("Why this?"))
      try shown.clickControl(at: 0)
      #expect(try shown.shows("Why this?"))
    }

    @Test("A reply posts its thread's draft")
    func replies() throws {
      let calls = Calls()
      let shown = screen([thread(reply: "Fixed")], calls: calls)
      defer { shown.close() }
      #expect(shown.firstTextField?.stringValue == "Fixed")
      // The header, the field, then Reply.
      try shown.clickControl(at: shown.controlFrames.count - 1)
      #expect(calls.log == ["reply t1"])
    }

    @Test("A new conversation posts or cancels, and says why it can't post")
    func newConversation() throws {
      let calls = Calls()
      let new = PullRequestNewThreadState(
        lineLabel: "Old lines 2\u{2013}4", body: "Nit", problem: nil)
      let shown = screen([], new: new, calls: calls)
      defer { shown.close() }
      #expect(try shown.shows("Comment on old lines 2\u{2013}4"))
      // The field, Cancel, then Comment.
      try shown.clickControl(at: 2)
      try shown.clickControl(at: 1)
      #expect(calls.log == ["post new", "cancel new"])

      let blocked = PullRequestNewThreadState(
        lineLabel: "New line 1", body: "x", problem: "A comment can be at most 65536 characters.")
      let refused = screen([], new: blocked, calls: calls)
      defer { refused.close() }
      #expect(try refused.shows("A comment can be at most 65536 characters."))
      // Comment is disabled: only the field and Cancel are listed.
      #expect(refused.controlFrames.count == 2)
    }
  }
#endif
