#if os(macOS) && DEBUG
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A window dragged narrower under a reader at the end of a long conversation, over a bottom
  /// bar that grows on the way as a wrapping toolbar does. The hang this looks for is the
  /// return from the top to the bottom row building every row between in one step of the drag.
  @Suite("Transcript edge return", .serialized)
  @MainActor
  struct TranscriptEdgeReturnTests {
    private static let turns = 150
    private static let wide: CGFloat = 900
    /// How far a step of the drag takes the pane, and the steps to its narrowest.
    private static let step: CGFloat = 12
    private static let steps = 20
    /// The bottom bar's height, and the step of the drag from which it is taller.
    private static let dock: CGFloat = 148
    private static let tallDock: CGFloat = 216
    private static let dockGrowsAt = 16
    /// Opening the conversation builds about this many rows: the ones on screen.
    private static let rowsOnScreen = 12
    /// The scrolls a width change has to put its reader back.
    private static let restoreScrolls = 8
    private static let lastLine = "The last line of the reply."
    private static let lateAnswer = "A late answer"

    private static func answer(_ turn: Int) -> String {
      "## Step \(turn)\n\nThe change touches `Sources/App/File\(turn).swift` and its tests. "
        + "It keeps the **old** behaviour for existing callers and adds a new path.\n\n"
        + "- first point about step \(turn)\n- second point, a little longer than the first\n"
        + "- third point\n\n```swift\nlet value\(turn) = compute(\(turn))\n```\n\n"
        + "Then a closing paragraph that wraps over a couple of lines at the column's width so "
        + "the row has a realistic height when it is laid out in the transcript."
    }

    /// A reply several screens tall, as a long streamed one is.
    private static func tallReply() -> String {
      var reply = "Streaming reply. "
      for index in 0..<80 {
        reply +=
          index % 9 == 8
          ? "\n\n```swift\nlet step\(index) = run(\(index))\n```\n\n"
          : "More words arrive for delta \(index) and wrap along the column. "
      }
      return reply + "\n\n" + lastLine
    }

    /// Turns of a question, a tool call and an answer, then the tall reply: far taller than the
    /// rows above it, so the heights the lazy rows estimate are far off.
    private func session() -> LiveConversation {
      var rows = (1...Self.turns).flatMap { turn -> [Row] in
        [
          TranscriptFixture.user("u\(turn)", "Look at step \(turn) please"),
          TranscriptFixture.toolCall("c\(turn)"),
          TranscriptFixture.toolResult("o\(turn)", callID: "c\(turn)"),
          TranscriptFixture.answer("a\(turn)", Self.answer(turn), responseID: "r\(turn)"),
        ]
      }
      rows.append(TranscriptFixture.answer("stream", Self.tallReply(), responseID: "rs"))
      return LiveConversation(ConversationViewState(header: TranscriptFixture.header, rows: rows))
    }

    /// The conversation open in the wide pane, at its end as opening leaves it.
    private func open(_ pane: TranscriptPane, _ conversation: LiveConversation) async throws
      -> OffscreenWindow<AnyView>
    {
      let window = transcriptScreen(
        DockedTranscriptHost(conversation: conversation, pane: pane), width: 1200, height: 800)
      window.settle(0.5)
      try await letTasksRun(window, milliseconds: 600)
      return window
    }

    /// The pane `steps` steps into the drag, laid out in the display cycle as the app's is.
    private func drag(_ pane: TranscriptPane, to steps: Int) {
      pane.width = Self.wide - CGFloat(steps) * Self.step
      pane.dock = steps >= Self.dockGrowsAt ? Self.tallDock : Self.dock
      commitFrames(for: 0.016)
    }

    /// How far above the viewport's clear bottom the text ending in `text` ends; `nil` when it
    /// is not in view.
    private func rest(of text: String, in frame: CommittedFrame) -> CGFloat? {
      frame.lines.last { $0.text.hasSuffix(text) }.map {
        frame.viewport.maxY - frame.bottomInset - $0.frame.maxY
      }
    }

    @Test("Each step of a drag builds the rows at the end alone, and commits the bottom row")
    func dragKeepsTheBottomRow() async throws {
      let pane = TranscriptPane(width: Self.wide, dock: Self.dock)
      let window = try await open(pane, session())
      defer { window.close() }
      let recorder = try CommittedFrames(window)
      var rests: [CGFloat] = []
      // Narrower step by step, and back.
      for index in 1..<(2 * Self.steps) {
        let before = HangTrace.tallies()
        var frames: [CommittedFrame] = []
        let built = RenderTally.recording {
          frames = recorder.recording { drag(pane, to: min(index, 2 * Self.steps - index)) }
        }
        #expect(built["row", default: 0] <= 2 * Self.rowsOnScreen, "step \(index)")
        let restores = HangTrace.tallies().count("transcript restore", since: before)
        #expect(restores < Self.restoreScrolls, "step \(index)")
        for frame in frames {
          rests.append(try #require(rest(of: Self.lastLine, in: frame), "step \(index)"))
        }
      }
      // The first steps leave the rows' width alone: they rest where opening the conversation
      // did, on the bottom row.
      let opened = try #require(rests.first)
      #expect(rests.allSatisfy { abs($0 - opened) < 1 }, "\(rests)")
    }

    @Test("After the drag the reader follows: a late answer is drawn on the bottom row, no pill")
    func followsAfterTheDrag() async throws {
      let conversation = session()
      let pane = TranscriptPane(width: Self.wide, dock: Self.dock)
      let window = try await open(pane, conversation)
      defer { window.close() }
      for steps in 1...Self.steps { drag(pane, to: steps) }
      // Layout forgets the drag's heights, which it would not follow again.
      try await letTasksRun(window, milliseconds: Int(FollowedHeights.memory * 1000) + 500)
      let recorder = try CommittedFrames(window)
      let rested = try #require(rest(of: Self.lastLine, in: recorder.settled))

      conversation.append(
        TranscriptFixture.answer("late", Self.lateAnswer, responseID: "late"))
      let frames = recorder.recording { commitFrames(for: 0.5) }
      let last = try #require(frames.last)
      let late = try #require(rest(of: Self.lateAnswer, in: last))
      #expect(abs(late - rested) < 1)
      let showsPill = try window.shows("Jump to latest") || window.shows("New output")
      #expect(!showsPill)
    }
  }
#endif
