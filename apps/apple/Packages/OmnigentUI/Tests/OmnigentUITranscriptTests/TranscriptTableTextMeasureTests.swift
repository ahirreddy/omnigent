#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Settled messages far from view, measured from their runs' laid-out sizes with no views.
  @Suite("Transcript table text measuring", .serialized)
  @MainActor
  struct TranscriptTableTextMeasureTests {
    static let width: CGFloat = 900
    private static let diagram = "Before\n\n```mermaid\ngraph TD\n  A --> B\n```"

    init() {
      SystemSideEffects.reset()
    }

    /// The style a text cell draws in, read from a chat environment with TextKit chosen.
    private func textStyle() -> TranscriptTableTextStyle {
      let environment = TranscriptTableEnvironment()
      var values = EnvironmentValues()
      values.messageTextRenderer = .textKit
      environment.values = values
      let style = TranscriptTableTextStyle(environment: environment)
      style.refresh()
      return style
    }

    private func row(_ message: Row) -> TranscriptTableRow {
      TranscriptTableRow(
        .segment(SegmentEntry(segment: .item(.message(message)), decorations: [:], duration: nil)))
    }

    /// Measures a block in a hosting view of its own.
    private func blockHeight(_ style: TranscriptTableTextStyle)
      -> (MarkdownBlock, Int, CGFloat) -> CGFloat
    {
      { block, piece, width in
        let view = TranscriptTableBlockView.make(environment: style.environment)
        view.show(block, piece: piece, width: width)
        return view.idealHeight
      }
    }

    @Test("A row far from view measures from its runs' sizes as tall as its cell shows it")
    func measuredFromSizes() throws {
      let style = textStyle()
      let worked = TranscriptFixture.answer(
        "a-worked", "## Step\n\nA paragraph with `code`.\n\n```swift\nlet a = 1\n```\n\n- one")
      var decoration = MessageDecoration()
      decoration.workedFor = 12
      let rows = [
        TranscriptTableRow(
          .segment(
            SegmentEntry(
              segment: .item(.message(worked)), decorations: [worked.id: decoration],
              duration: nil))),
        row(TranscriptFixture.user("u-far", "A question that is short.")),
        row(TranscriptFixture.answer("a-diagram-far", Self.diagram)),
      ]
      for shown in rows {
        let message = try #require(TranscriptTableTextMessage.make(shown, ramp: style.ramp))
        let measured = try #require(
          TranscriptTableTextCell.measuredHeight(
            of: message, style: style, width: Self.width, blockHeight: blockHeight(style)))
        let cell = TranscriptTableTextCell(style: style)
        cell.show(shown, version: 0, width: Self.width)
        #expect(measured == cell.idealHeight, "\(shown.id)")
      }
    }
  }
#endif
