#if os(macOS) && DEBUG
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The width of the pane a transcript sits in, which a test changes as a resize does.
  @MainActor
  @Observable
  private final class PaneWidth {
    var value: CGFloat

    init(_ value: CGFloat) {
      self.value = value
    }
  }

  /// The transcript in a pane whose width changes under it.
  private struct ResizedTranscriptHost: View {
    let conversation: LiveConversation
    let width: PaneWidth
    var actions = ConversationActions()

    var body: some View {
      LiveTranscriptHost(conversation: conversation, actions: actions)
        .frame(width: width.value)
    }
  }

  /// The hang these look for is a layout pass that builds rows far from the viewport. A new
  /// width leaves every row's height unknown: the lazy stack then builds the rows above the
  /// viewport to find where it is, and a scroll to the end builds the rows on the way there.
  @Suite("Transcript width change cost", .serialized)
  @MainActor
  struct TranscriptWidthChangeCostTests {
    /// Narrower than the rows grow to, so a wider pane changes every row's width.
    private static let narrow: CGFloat = 500
    private static let wide: CGFloat = 900
    private static let height: CGFloat = 700
    private static let turns = 400
    /// Opening the conversation builds about this many rows: the ones on screen.
    private static let rowsOnScreen = 12

    /// Turns of a question, a tool call and an answer with a code block of varying length, so
    /// rows differ in height and none keeps its height at another width.
    private func session() -> LiveConversation {
      let rows = (0..<Self.turns).flatMap { turn -> [Row] in
        let fields = (0..<(3 + turn % 9)).map { "  var field\($0): Int = \($0)" }
        let answer = [
          "## Step \(turn)",
          "The handler calls `process(batch:)` once per item, which is quadratic; batching fixes it.",
          "```swift\nstruct Model\(turn) {\n\(fields.joined(separator: "\n"))\n}\n```",
          "- Moved parsing out of the loop\n- Kept the API\n- Added a test",
        ]
        return [
          TranscriptFixture.user("u\(turn)", "Look at step \(turn)"),
          TranscriptFixture.toolCall("c\(turn)"),
          TranscriptFixture.toolResult("o\(turn)", callID: "c\(turn)"),
          TranscriptFixture.answer(
            "a\(turn)", answer.joined(separator: "\n\n"), responseID: "r\(turn)"),
        ]
      }
      var state = ConversationViewState(header: TranscriptFixture.header, rows: rows)
      state.hasMoreHistory = true
      return LiveConversation(state)
    }

    /// The conversation open in a narrow pane, at its end as opening leaves it.
    private func narrowPane(
      _ width: PaneWidth, actions: ConversationActions = ConversationActions()
    ) async throws -> OffscreenWindow<AnyView> {
      let host = ResizedTranscriptHost(conversation: session(), width: width, actions: actions)
      let window = transcriptScreen(host, width: Self.wide, height: Self.height)
      window.settle(0.5)
      try await letTasksRun(window, milliseconds: 600)
      return window
    }

    @Test("Dragging the pane wider under a reader at the end builds a screen of rows a step")
    func dragAtEndBuildsVisibleRows() async throws {
      let width = PaneWidth(Self.narrow)
      let window = try await narrowPane(width)
      defer { window.close() }
      let steps = 20

      let dragging = RenderTally.recording {
        for step in 1...steps {
          width.value = Self.narrow + (Self.wide - Self.narrow) * CGFloat(step) / CGFloat(steps)
          window.settle(0.016)
        }
        window.settle(0.5)
      }
      #expect(dragging["row", default: 0] <= steps * Self.rowsOnScreen)
    }

    @Test("Widening the pane of a reader mid-conversation builds the rows on screen, not the rest")
    func wideningMidConversationBuildsVisibleRows() async throws {
      let width = PaneWidth(Self.narrow)
      let log = HostLog()
      var actions = ConversationActions()
      actions.loadOlder = { log.add("older") }
      let window = try await narrowPane(width, actions: actions)
      defer { window.close() }
      let viewport = TranscriptScrollDriver(screen: window)
      // A reader who scrolled up, which is what stops following.
      let scroll = try #require(viewport.scrollView)
      window.liveScroll(scroll, began: true)
      viewport.move(to: viewport.maximumOffset / 2)
      window.liveScroll(scroll, began: false)
      try await letTasksRun(window, milliseconds: 300)
      let before = viewport.fractionRead

      let widening = RenderTally.recording {
        width.value = Self.wide
        window.settle(0.5)
      }
      // Three screens: the first rows, where the rows take the width, and the reader's own.
      #expect(widening["row", default: 0] <= 3 * Self.rowsOnScreen)
      // The turns are much alike, so the same place is the same share of the conversation.
      #expect(abs(viewport.fractionRead - before) < 0.1)
      // The rows' trip to the top is not a reader asking for older history.
      #expect(log.entries.isEmpty)
    }
  }
#endif
