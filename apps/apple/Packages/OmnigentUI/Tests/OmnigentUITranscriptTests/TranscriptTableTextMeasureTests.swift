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

    private struct Host: View {
      let conversation: LiveConversation

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: ConversationActions(),
          scrollToLatestRequest: conversation.scrollRequest
        )
        .environment(\.messageTextRenderer, .textKit)
      }
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

    @Test("A live resize lays text out at snapped widths, and at the exact one once it ends")
    func liveResize() async throws {
      let metrics = { (width: CGFloat, snap: CGFloat) in
        TranscriptTableTextMetrics(
          width: width, layoutWidth: .regular, maxWidth: Theme.transcriptWidth, snap: snap)
      }
      #expect(metrics(500, 32).columnWidth == 448)
      #expect(metrics(900, 32).columnWidth == Theme.transcriptWidth, "a full column is exact")
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(3)))
      let window = transcriptScreen(Host(conversation: conversation), width: 520, height: 700)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let scrollView = try #require(driver.scrollView)
      let table = try #require(scrollView.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      /// The widths the answers on screen lay their text out at.
      func answerWidths() -> [CGFloat] {
        controller.model.rows.indices.compactMap { index in
          guard controller.model.rows[index].kind == .answer,
            let cell = controller.realizedCell(at: index) as? TranscriptTableTextCell
          else { return nil }
          return cell.runs.first?.view.frame.width
        }
      }
      controller.liveResizeChanged(true)
      for step in 1...5 {
        scrollView.setFrameSize(
          NSSize(width: 520 - CGFloat(step) * 3, height: scrollView.frame.height))
        window.settle(0.02)
        let widths = answerWidths()
        #expect(!widths.isEmpty)
        #expect(widths.allSatisfy { $0.truncatingRemainder(dividingBy: 32) == 0 }, "\(widths)")
      }
      controller.liveResizeChanged(false)
      window.settle(0.05)
      let exact = metrics(controller.model.width, 0).columnWidth
      #expect(answerWidths().allSatisfy { $0 == exact }, "\(answerWidths()) at \(exact)")
      for index in controller.model.rows.indices where controller.realizedCell(at: index) != nil {
        #expect(!controller.model.needsMeasure(at: index), "row \(index)")
      }
    }
  }
#endif
