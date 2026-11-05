import Testing

@testable import OmnigentUIComponents

/// The web's turn folding: messages stay visible and each run of work between them folds.
@Suite("Turn folds")
struct TurnFoldTests {
  @Test("narration stays visible and each work run between messages folds on its own")
  func narrationStaysVisible() {
    func tool(_ id: String, _ title: String) -> Row {
      Row(
        id: id, role: .tool, activity: Activity(kind: .toolCall, title: title), callId: id,
        responseId: "r")
    }
    let rows = [
      Row(id: "u", role: .user, text: "Hi"),
      tool("c1", "Read"),
      Row(id: "a1", role: .assistant, text: "Looking at the tests next.", responseId: "r"),
      tool("c2", "Bash"),
      tool("c3", "Bash"),
      Row(id: "a2", role: .assistant, text: "All green.", responseId: "r"),
      Row(
        id: "think", role: .tool, activity: Activity(kind: .reasoning, title: "Reasoning"),
        responseId: "r"),
    ]
    let segments = TurnLayout.segments(TranscriptLayout.items(for: rows), isRunning: false)
    #expect(segments.map(\.id) == ["u", "worked:tools:c1", "a1", "worked:tools:c2", "a2"])
    // Trailing reasoning joins the last run instead of opening a fold after the answer.
    #expect(segments[3].items.map(\.id) == ["tools:c2", "think"])
    #expect(TranscriptLayoutMemo.lastAnswerIDs(segments) == ["r": "a2"])
  }

  @Test("a settled turn without a message stays unfolded")
  func noMessageNoFold() {
    let rows = [
      Row(id: "u", role: .user, text: "Hi"),
      Row(id: "c1", role: .tool, activity: Activity(kind: .toolCall, title: "Read"), callId: "a"),
      Row(id: "o1", role: .tool, activity: Activity(kind: .toolResult, title: "out"), callId: "a"),
      Row(id: "u2", role: .user, text: "Again"),
    ]
    let segments = TurnLayout.segments(TranscriptLayout.items(for: rows), isRunning: false)
    #expect(segments.map(\.id) == ["u", "tools:c1", "u2"])
  }
}
