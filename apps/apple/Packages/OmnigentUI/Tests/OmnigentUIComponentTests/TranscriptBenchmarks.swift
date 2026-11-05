import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// Timings for the transcript's hot pure functions on a long, seeded-like conversation (the
/// shape `seed-large-fixtures.py` writes). Run with
/// `OMNIGENT_BENCH=1 swift test --package-path apps/apple/Packages/OmnigentUI --filter TranscriptBenchmarks`;
/// each prints its numbers, and `docs/performance.md` keeps the baseline.
@Suite("Transcript benchmarks")
@MainActor
struct TranscriptBenchmarks {
  nonisolated static let isEnabled = ProcessInfo.processInfo.environment["OMNIGENT_BENCH"] != nil

  /// A seeded-like answer: a heading, prose and a list, with code, a table, a task list, math
  /// and a Mermaid diagram on some turns.
  static func answer(_ turn: Int) -> String {
    var parts = [
      "## Step \(turn)",
      "The handler calls `process(batch:)` once per item, which is quadratic; batching fixes it. "
        + "See [the note](https://example.com/design).",
      "- Moved parsing out of the loop\n- Kept the API\n  - nested *detail*\n- Added a test",
    ]
    if turn.isMultiple(of: 2) {
      let lines = (0..<(40 + turn % 60)).map { "  var field\($0): [String: Int] = [\"k\": \($0)]" }
      parts.append("```swift\nstruct Model\(turn) {\n\(lines.joined(separator: "\n"))\n}\n```")
    }
    if turn.isMultiple(of: 3) {
      let rows = (0..<8).map { "| \($0) | team-\($0 % 4) | done | \($0 * 37) | `item_\($0)` |" }
      parts.append(
        "| Step | Owner | Status | ms | Notes |\n| --- | :---: | --- | ---: | --- |\n"
          + rows.joined(separator: "\n"))
    }
    if turn.isMultiple(of: 4) { parts.append("- [x] reproduce\n- [ ] ship") }
    if turn.isMultiple(of: 5) {
      parts.append("Cost \\(O(n \\log n)\\):\n\n$$\nT(n) = 2T(n/2) + n\n$$")
    }
    if turn.isMultiple(of: 7) { parts.append("```mermaid\ngraph TD\n  A --> B\n```") }
    return parts.joined(separator: "\n\n")
  }

  /// `turns` turns of a user message, two tool calls with results and an answer.
  static func rows(turns: Int) -> [Row] {
    (1...turns).flatMap { turn -> [Row] in
      let response = "r\(turn)"
      return [
        Row(id: "u\(turn)", role: .user, text: "Look at step \(turn)", responseId: "t\(turn)"),
        Row(
          id: "c\(turn)", role: .tool, activity: Activity(kind: .toolCall, title: "bash"),
          callId: "call\(turn)", responseId: response),
        Row(
          id: "o\(turn)", role: .tool,
          activity: Activity(kind: .toolResult, title: "bash", summary: "ok"),
          callId: "call\(turn)", responseId: response),
        Row(id: "a\(turn)", role: .assistant, text: answer(turn), responseId: response),
      ]
    }
  }

  static func conversation(_ rows: [Row], running: Bool) -> ConversationViewState {
    ConversationViewState(
      header: SessionHeader(id: "bench", title: "Bench", status: running ? .running : .idle),
      rows: rows)
  }

  /// Milliseconds per call of `body`, over `count` calls.
  static func perCall(_ count: Int, _ body: (Int) -> Void) -> Double {
    let elapsed = ContinuousClock().measure {
      for index in 0..<count { body(index) }
    }
    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    return seconds * 1_000 / Double(count)
  }

  static func format(_ milliseconds: Double) -> String {
    milliseconds.formatted(.number.precision(.fractionLength(2)))
  }

  @Test("benchmark: transcript layout per streamed delta", .enabled(if: isEnabled))
  func layoutPerDelta() {
    for turns in [100, 500, 1_000] {
      var rows = Self.rows(turns: turns)
      rows[rows.count - 1].isStreaming = true
      let memo = TranscriptLayoutMemo()
      var state = Self.conversation(rows, running: true)
      _ = memo.entries(for: state)
      let perDelta = Self.perCall(50) { index in
        state.rows[state.rows.count - 1].text += " word\(index)"
        _ = memo.entries(for: state)
      }
      let segments = Self.perCall(50) { _ in _ = TranscriptView.segments(for: state) }
      var copy = state.rows
      copy[copy.count - 1].text += "!"
      let compare = Self.perCall(50) { _ in _ = copy == state.rows }
      print(
        "benchmark: \(state.rows.count) rows; layout per delta \(Self.format(perDelta)) ms, "
          + "a full fold \(Self.format(segments)) ms, comparing rows \(Self.format(compare)) ms")
    }
  }

  @Test("benchmark: markdown parse per answer, uncached", .enabled(if: isEnabled))
  func markdownParse() {
    let answers = (1...200).map(Self.answer)
    let perAnswer = Self.perCall(answers.count) { _ = MarkdownParser.parse(answers[$0]) }
    let bytes = answers.map(\.utf8.count).reduce(0, +) / answers.count
    print("benchmark: markdown parse, \(bytes) B per answer: \(Self.format(perAnswer)) ms")
  }

  @Test("benchmark: code highlighting per block", .enabled(if: isEnabled))
  func codeHighlight() {
    let blocks = (1...50).map { turn in
      (0..<100).map { "  let value\($0) = compute(\"key\($0)\", \(turn * $0)) // note" }
        .joined(separator: "\n")
    }
    let spans = blocks.map { CodeHighlighting.spans($0, language: "swift") }
    let tokenizing = Self.perCall(blocks.count) { index in
      _ = CodeHighlighting.spans(blocks[index], language: "swift")
    }
    let coloring = Self.perCall(blocks.count) { index in
      _ = CodeHighlighting.attributed(blocks[index], spans: spans[index], scheme: .dark)
    }
    print(
      "benchmark: highlight a 100-line Swift block (\(spans[0].count) spans): tokenize "
        + "\(Self.format(tokenizing)) ms, color \(Self.format(coloring)) ms")
  }
}
