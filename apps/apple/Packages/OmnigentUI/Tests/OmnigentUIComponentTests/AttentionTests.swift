import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("One needs-you signal")
struct AttentionTests {
  @Test("States sort Needs you > Failed > Working > Unread > Idle")
  func order() {
    #expect(
      SessionAttentionState.allCases.sorted() == [.needsYou, .failed, .working, .unread, .idle])
    #expect(SessionAttentionState(status: .needsResponse, failure: nil) == .needsYou)
    #expect(SessionAttentionState(status: .running, failure: nil) == .working)
    #expect(SessionAttentionState(status: .idle, failure: "boom") == .failed)
    #expect(SessionAttentionState(status: .idle, failure: nil) == .idle)
  }

  private func agree(_ sidebar: SidebarViewState, _ inbox: InboxViewState) {
    let sessions = sidebar.list.sessions
    let needing = sessions.filter { $0.attention == .needsYou }
    #expect(sidebar.list.filterCounts[.needsResponse] == needing.count)
    #expect(sidebar.inboxCount == needing.count)
    #expect(inbox.needsYouCount == needing.count)
    #expect(
      sidebar.list.filterCounts[.running]
        == sessions.count { $0.attention == .working && !$0.isArchived })
    // Every session that needs you has a request count, and only those.
    #expect(Set(sidebar.list.attentionCounts.keys) == Set(needing.map(\.id)))
    // The Inbox lists exactly those requests for each session that needs you.
    for session in needing {
      let items = inbox.items.filter { $0.sessionId == session.id && $0.decision != nil }
      #expect(items.count == sidebar.list.attentionCounts[session.id], "\(session.id)")
    }
  }

  @Test("Streaming: the sample's sidebar, Inbox and header agree")
  func streamingSampleAgrees() {
    agree(PreviewData.sidebar, PreviewData.inbox)
    let current = PreviewData.sidebar.list.sessions.first { $0.id == PreviewData.sessionID }
    #expect(current?.attention == .working)
    var conversation = PreviewData.shellConversation
    conversation.decisions = []
    #expect(SessionStatusLine(conversation).text == "Running \u{00B7} Fixing the expiry test")
  }

  @Test("Pending approvals: the dock, row, counts, Inbox and header agree")
  func approvalsSampleAgrees() {
    let sidebar = PreviewData.approvalsSidebar
    agree(sidebar, PreviewData.approvalsInbox)
    let requests = PreviewData.approvalRequests.count
    let current = sidebar.list.sessions.first { $0.id == PreviewData.sessionID }
    #expect(current?.attention == .needsYou)
    #expect(sidebar.list.attentionCounts[PreviewData.sessionID] == requests)
    #expect(sidebar.inboxCount == 3)

    var conversation = PreviewData.shellConversation
    conversation.decisions = PreviewData.approvalRequests
    // The server may still say running; pending decisions win and nothing spins.
    conversation.header.status = .running
    let line = SessionStatusLine(conversation)
    #expect(line.kind == .waiting)
    #expect(line.text == "Waiting for you \u{00B7} \(requests) requests")
    #expect(conversation.pendingDecisions.count == requests)
  }

  @Test("The status line reports only what the session reported")
  func statusLine() {
    var state = PreviewData.shellConversation
    state.decisions = [PreviewData.choice]
    state.header.readOnly = true
    #expect(SessionStatusLine(state).text == "Waiting for a response \u{00B7} 1 request")

    state = PreviewData.failedConversation
    #expect(
      SessionStatusLine(state).text
        == "Failed \u{00B7} The provider rejected the request: invalid API key.")

    state = PreviewData.shellConversation
    state.decisions = []
    state.sections = state.sections.filter { $0.id != "todos" && !$0.id.hasPrefix("files-") }
    state.rows = [
      Row(
        id: "t1", role: .tool, text: "",
        activity: Activity(kind: .toolCall, title: "Run cargo test", status: "in_progress"))
    ]
    #expect(SessionStatusLine(state).text == "Running \u{00B7} Run cargo test")
    state.rows = []
    #expect(SessionStatusLine(state).text == "Running")

    state.header.status = .idle
    #expect(SessionStatusLine(state).text == "Ready")
    state.rows = [Row(id: "a1", role: .assistant, text: "Done.")]
    #expect(SessionStatusLine(state).text == "Finished")
    state.sections.append(
      EventSection(id: "files-default", title: "Changed files", summary: "3 files in default"))
    #expect(SessionStatusLine(state).text == "Finished \u{00B7} 3 files changed")
    state.sections.append(
      EventSection(id: "files-sandbox", title: "Changed files", summary: "Loading changed files…"))
    #expect(SessionStatusLine(state).text == "Finished \u{00B7} 3 files changed")
    state.rows[0].interrupted = true
    #expect(SessionStatusLine(state).text == "Stopped")
  }
}
