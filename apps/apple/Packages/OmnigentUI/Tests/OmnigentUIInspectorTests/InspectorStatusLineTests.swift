import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Inspector: the session's status line")
struct InspectorStatusLineTests {
  private func state(
    _ status: TurnStatus = .idle, readOnly: Bool = false, failure: String? = nil,
    rows: [Row] = [], decisions: [DecisionCard] = [], sections: [EventSection] = []
  ) -> ConversationViewState {
    ConversationViewState(
      header: SessionHeader(
        id: "s", title: "S", status: status, readOnly: readOnly, failureMessage: failure),
      rows: rows, decisions: decisions, sections: sections)
  }

  private let user = Row(id: "u", role: .user, text: "hi")
  private let assistant = Row(id: "a", role: .assistant, text: "hello")

  @Test("With nothing in the transcript it's ready")
  func ready() {
    let line = SessionStatusLine(state())
    #expect(line.kind == .ready)
    #expect(line.text == "Ready")
    #expect(line.systemImage == "circle")
    #expect(line.tint == Theme.secondary)
  }

  @Test("A waiting request counts, for you or for whoever owns a read-only session")
  func waitingRequests() {
    let card = PreviewData.subagentCommand
    let one = SessionStatusLine(state(decisions: [card]))
    #expect(one.kind == .waiting)
    #expect(one.text == "Waiting for you \u{00B7} 1 request")
    #expect(one.systemImage == "hand.raised.fill")
    #expect(one.tint == Theme.attention)
    var other = card
    other.id = "other"
    let two = SessionStatusLine(state(readOnly: true, decisions: [card, other]))
    #expect(two.text == "Waiting for a response \u{00B7} 2 requests")
  }

  @Test("An answered request no longer waits")
  func answered() {
    let card = PreviewData.subagentCommand
    var answered = state(decisions: [card])
    answered.decisionPhases[card.id] = .answered(summary: "Yes")
    #expect(SessionStatusLine(answered).kind == .ready)
    answered.decisionPhases[card.id] = .failed(message: "No")
    #expect(SessionStatusLine(answered).kind == .waiting)
  }

  @Test("A session that needs a response waits without a request")
  func needsResponse() {
    #expect(SessionStatusLine(state(.needsResponse)).text == "Waiting for you")
    #expect(
      SessionStatusLine(state(.needsResponse, readOnly: true)).text == "Waiting for a response")
  }

  @Test("A failure shows its message")
  func failed() {
    let line = SessionStatusLine(state(failure: "Out of memory"))
    #expect(line.kind == .failed)
    #expect(line.text == "Failed \u{00B7} Out of memory")
    #expect(line.systemImage == "exclamationmark.triangle.fill")
    #expect(line.tint == Theme.failure)
  }

  @Test("Running names the task in progress, or just says running")
  func running() {
    let plain = SessionStatusLine(state(.running))
    #expect(plain.kind == .running)
    #expect(plain.text == "Running")
    #expect(plain.systemImage == "circle.dotted.circle")
    #expect(plain.tint == Theme.running)
    let todos = EventSection(
      id: "todos", title: "Plan", summary: "",
      details: [
        DetailSection(id: "1", title: "Completed: a", text: "Old"),
        DetailSection(id: "2", title: "In progress: b", text: "Writing tests"),
      ])
    let working = SessionStatusLine(state(.running, sections: [todos]))
    #expect(working.text == "Running \u{00B7} Writing tests")
    let blank = EventSection(
      id: "todos", title: "Plan", summary: "",
      details: [DetailSection(id: "1", title: "In progress: b", text: "")])
    #expect(SessionStatusLine(state(.running, sections: [blank])).text == "Running")
    var reading = state(.running)
    reading.transcriptStatus = TranscriptStatus(
      isEmpty: false, lastInterrupted: false, activityTitle: "Reading a file")
    #expect(SessionStatusLine(reading).text == "Running \u{00B7} Reading a file")
  }

  @Test("A finished session counts its changed files, across sections")
  func finished() {
    let done = SessionStatusLine(state(rows: [user, assistant]))
    #expect(done.kind == .finished)
    #expect(done.text == "Finished")
    #expect(done.systemImage == "checkmark.circle")
    #expect(done.tint == Theme.secondary)
    let one = EventSection(id: "files-a", title: "", summary: "1 file in repo")
    let many = EventSection(id: "files-b", title: "", summary: "3 files in other")
    #expect(
      SessionStatusLine(state(rows: [user, assistant], sections: [one])).text
        == "Finished \u{00B7} 1 file changed")
    #expect(
      SessionStatusLine(state(rows: [user, assistant], sections: [one, many])).text
        == "Finished \u{00B7} 4 files changed")
  }

  @Test("A summary that doesn't count files isn't read as a count")
  func unreadableSummary() {
    let words = EventSection(id: "files-a", title: "", summary: "No changes yet")
    let number = EventSection(id: "files-b", title: "", summary: "3 commits in repo")
    #expect(
      SessionStatusLine(state(rows: [user, assistant], sections: [words, number])).text
        == "Finished"
    )
  }

  @Test("An interrupted turn says it was stopped")
  func stopped() {
    let stoppedReply = Row(id: "a", role: .assistant, text: "hel", interrupted: true)
    let line = SessionStatusLine(state(rows: [user, stoppedReply]))
    #expect(line.kind == .finished)
    #expect(line.text == "Stopped")
  }
}

@Suite("Inspector: reading sections")
struct InspectorSectionReadingTests {
  @Test("A todo's prefix is its state")
  func todos() {
    let section = EventSection(
      id: "todos", title: "", summary: "",
      details: [
        DetailSection(id: "a", title: "Completed: x", text: "One"),
        DetailSection(id: "b", title: "In Progress: x", text: "Two"),
        DetailSection(id: "c", title: "Pending: x", text: "Three"),
        DetailSection(id: "d", title: "", text: "Four"),
      ])
    let states = SectionReading.todos(section).map(\.state)
    #expect(states == [.completed, .inProgress, .pending, .pending])
  }

  @Test("Usage reads its numbers and its lines per model")
  func usage() {
    let section = EventSection(
      id: "usage", title: "", summary: "",
      details: [
        DetailSection(id: "context_tokens", title: "", text: "500"),
        DetailSection(id: "context_window", title: "", text: "1000"),
        DetailSection(id: "total_cost_usd", title: "", text: "1.25"),
        DetailSection(id: "usage_by_model", title: "", text: "opus: 1\nsonnet: 2"),
      ])
    let usage = SectionReading.usage(section)
    #expect(usage.fraction == 0.5)
    #expect(usage.totalCost == 1.25)
    #expect(usage.byModel == ["opus: 1", "sonnet: 2"])
    let empty = SectionReading.usage(EventSection(id: "usage", title: "", summary: ""))
    #expect(empty.fraction == nil)
    #expect(empty.byModel.isEmpty)
  }

  @Test("The context fraction needs a window and never passes full")
  func fraction() {
    #expect(SectionReading.Usage(contextTokens: 5, contextWindow: 0, byModel: []).fraction == nil)
    #expect(SectionReading.Usage(contextTokens: 5, byModel: []).fraction == nil)
    #expect(SectionReading.Usage(contextWindow: 5, byModel: []).fraction == nil)
    #expect(SectionReading.Usage(contextTokens: 9, contextWindow: 5, byModel: []).fraction == 1)
  }

  @Test(
    "A changed file's letter comes from its status",
    arguments: [
      ("added", "A"), ("NEW", "A"), ("created", "A"), ("untracked", "A"), ("deleted", "D"),
      ("removed", "D"), ("renamed", "R"), ("modified", "M"), ("changed", "M"), ("updated", "M"),
      ("copied", "C"), ("", ""),
    ])
  func letters(status: String, letter: String) {
    #expect(SectionReading.ChangedFile(path: "p", status: status).letter == letter)
  }

  @Test("A viewer's initials come from the name's parts, and Idle means idle")
  func viewers() {
    let section = EventSection(
      id: "presence", title: "", summary: "",
      details: [
        DetailSection(id: "a", title: "Ada Lovelace", text: "Active"),
        DetailSection(id: "b", title: "grace_hopper@example.com", text: "Idle"),
      ])
    let viewers = SectionReading.viewers(section)
    #expect(viewers[0].initials == "AL")
    #expect(!viewers[0].isIdle)
    #expect(viewers[1].initials == "GH")
    #expect(viewers[1].isIdle)
  }
}
