import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("States and copy")
struct StatesAndCopyTests {
  private func header(_ status: TurnStatus, readOnly: Bool = false) -> SessionHeader {
    SessionHeader(id: "s", title: "Session", status: status, readOnly: readOnly)
  }

  @Test("One empty-state heading; the second line says what to do next")
  func emptyState() {
    var state = ConversationViewState(header: header(.idle))
    #expect(EmptyTranscriptView.title(state) == "What should we work on?")
    #expect(EmptyTranscriptView.detail(state) == "Send a message to start this session.")
    state.rows = [Row(id: "l", role: .tool, text: "", isActivityOnly: true)]
    #expect(
      EmptyTranscriptView.detail(state) == "Send a message to start this session.",
      "lifecycle rows are not the user's business")
    state.header.readOnly = true
    #expect(EmptyTranscriptView.detail(state) == "This session has no messages yet.")
    state.hasMoreHistory = true
    #expect(EmptyTranscriptView.title(state) == "No messages on this page")
  }

  @Test("The live turn counts from the store's start, else the prompt's timestamp")
  func elapsedStart() {
    let sent = Date(timeIntervalSince1970: 1_000)
    var state = ConversationViewState(
      header: header(.running), rows: [Row(id: "u", role: .user, text: "Go")],
      timestamps: ["u": sent])
    #expect(TurnElapsed.start(in: state) == sent)
    state.timestamps = [:]
    #expect(TurnElapsed.start(in: state) == nil)
    state.rows[0].createdAt = sent
    #expect(TurnElapsed.start(in: state) == sent, "the row's own time is the fallback")
    let started = Date(timeIntervalSince1970: 1_005)
    state.turnStartedAt = started
    #expect(TurnElapsed.start(in: state) == started)
    state.header.status = .idle
    #expect(TurnElapsed.start(in: state) == nil, "only while running")
    #expect(
      TurnElapsed.label(since: started, now: started.addingTimeInterval(12.7)) == "Working · 12s")
    #expect(TurnElapsed.label(since: nil, now: started) == "Working")
    #expect(TurnElapsed.worked(64) == "Worked for 1m 4s")
  }

  @Test("The fold is titled by its steps, never by Working or the duration")
  func foldTitle() {
    let row = Row(id: "r", role: .assistant, text: "Thinking", responseId: "x")
    #expect(WorkedFold.title(items: [.message(row)]) == "1 step")
    let call = Row(id: "c", role: .tool, text: "", callId: "c1", responseId: "x")
    let tools = TranscriptItem.tools(
      id: "t", entries: [ToolEntry(call: call, result: nil), ToolEntry(call: call, result: nil)])
    #expect(WorkedFold.title(items: [.message(row), tools]) == "3 steps")
  }

  @Test("A settled answer carries its turn's duration; the fold and streaming rows do not")
  func workedForDecoration() {
    let state = PreviewData.shellConversation
    let entries = TranscriptLayoutMemo().entries(for: state)
    let answer = entries.compactMap { $0.decorations["item_a1"] }.first
    #expect(answer?.workedFor == 106)
    let folded = entries.filter {
      if case .worked = $0.segment { return true }
      return false
    }
    #expect(folded.allSatisfy { $0.decorations.values.allSatisfy { $0.workedFor == nil } })
  }

  @Test("Unsupported content names what happened, not the core's generic title")
  func unsupportedTitle() {
    #expect(UnsupportedContentView.title("Message content") == "Content this app can\u{2019}t show")
    #expect(UnsupportedContentView.title(" ") == "Content this app can\u{2019}t show")
    #expect(UnsupportedContentView.title("Audio") == "Audio \u{00B7} not shown in this app")
  }

  @Test("The fork dialog's buttons use its title's verb")
  func forkVerb() {
    func state(_ kind: ForkViewState.Kind) -> ForkViewState {
      ForkViewState(id: "f", kind: kind, agents: [], agentID: "", directory: "")
    }
    #expect(state(.session).verb == "Clone")
    #expect(state(.fromMessage(rowID: "r")).verb == "Fork")
    #expect(state(.fromMessage(rowID: "r")).title.hasPrefix("Fork"))
    #expect(state(.anotherDirectory).verb == "Continue")
  }

  @Test("Avatar initials and colors stay legible: white text above 4.5:1")
  func avatars() {
    #expect(AuthorAvatar.initials("sam.lee") == "SL")
    #expect(AuthorAvatar.initials("Priya") == "P")
    #expect(AuthorAvatar.initials("") == "?")
    func luminance(_ hex: UInt32) -> Double {
      let channels = [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) / 255 }
      let linear = channels.map { $0 <= 0.039_28 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
      return 0.212_6 * linear[0] + 0.715_2 * linear[1] + 0.072_2 * linear[2]
    }
    for color in AuthorAvatar.palette + [AuthorAvatar.idle] {
      #expect(1.05 / (luminance(color) + 0.05) >= 4.5, "white on \(String(color, radix: 16))")
    }
  }
}
