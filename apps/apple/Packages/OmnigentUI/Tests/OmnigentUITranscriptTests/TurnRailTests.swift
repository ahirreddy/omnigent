import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Turn rail")
@MainActor
struct TurnRailTests {
  /// The address of the array's buffer, to tell a kept array from an equal copy.
  private func storage(_ turns: [TranscriptTurn]) -> Int {
    turns.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
  }

  @Test("one turn per user message, in order, with its text")
  func turnsFollowUserMessages() {
    let memo = TranscriptLayoutMemo()
    let state = TranscriptMemoTests.conversation(rows: TranscriptMemoTests.rows)
    #expect(
      memo.turns(for: state) == [
        TranscriptTurn(id: "u1", text: "Fix the bug"),
        TranscriptTurn(id: "u2", text: "And add tests"),
      ])
  }

  @Test("a streamed delta keeps the same turns array; a new message replaces it")
  func streamingKeepsTurns() {
    var rows = TranscriptBenchmarks.rows(turns: 30)
    rows[rows.count - 1].isStreaming = true
    let memo = TranscriptLayoutMemo()
    var state = TranscriptBenchmarks.conversation(rows, running: true)
    let first = memo.turns(for: state)
    #expect(first.count == 30)
    for word in ["more", "words", "here"] {
      state.rows[state.rows.count - 1].text += " \(word)"
      let streamed = memo.turns(for: state)
      #expect(storage(streamed) == storage(first))
    }
    #expect(memo.prefixReuses == 3)

    state.rows.append(Row(id: "u31", role: .user, text: "Next"))
    let grown = memo.turns(for: state)
    #expect(grown.count == 31)
    #expect(grown.last == TranscriptTurn(id: "u31", text: "Next"))
  }

  @Test("the active turn owns the middle of the visible rows")
  func activeTurn() {
    let order = ["u1", "a1", "u2", "a2", "w2", "u3", "a3"]
    let turns: Set = ["u1", "u2", "u3"]
    let active = { (order: [String], visible: Set<String>) in
      TurnRailModel.activeTurn(order: order, turns: turns, visible: visible)
    }
    #expect(active(order, ["a2", "w2", "u3"]) == "u2")
    #expect(active(order, ["u3", "a3"]) == "u3")
    // Rows above the first turn belong to it.
    #expect(active(["top"] + order, ["top"]) == "u1")
    #expect(active(order, []) == nil)
  }

  @Test("the preview is the first answer after the turn, never the next turn's")
  func responsePreview() {
    let memo = TranscriptLayoutMemo()
    var rows = TranscriptMemoTests.rows
    rows.insert(Row(id: "u0", role: .user, text: "Hello"), at: 0)
    let entries = memo.entries(for: TranscriptMemoTests.conversation(rows: rows))
    #expect(TurnRailModel.responsePreview(after: "u1", in: entries) == "Looking")
    #expect(TurnRailModel.responsePreview(after: "u0", in: entries).isEmpty)
    #expect(TurnRailModel.responsePreview(after: "missing", in: entries).isEmpty)
  }

  @Test("publishing equal turns or the same active turn changes nothing")
  func modelGuards() {
    let model = TurnRailModel()
    let turns = [TranscriptTurn(id: "u1", text: "a"), TranscriptTurn(id: "u2", text: "b")]
    model.setTurns(turns)
    model.setActive("u1")
    #expect(model.turns == turns)
    #expect(model.activeID == "u1")
  }
}
