#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Settled messages in the table transcript drawn as TextKit text in AppKit cells: how they
  /// size and measure, which rows they take, the answers laid out ahead, and their reuse.
  @Suite("Transcript table text cells", .serialized)
  @MainActor
  struct TranscriptTableTextCellTests {
    static let width: CGFloat = 900

    init() {
      SystemSideEffects.reset()
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

    private static let diagram = "Before\n\n```mermaid\ngraph TD\n  A --> B\n```"

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

    @Test("An answer's height is its text's TextKit measurement plus the row's spacing")
    func answerSizing() throws {
      let style = textStyle()
      #expect(style.isEnabled)
      let cell = TranscriptTableTextCell(style: style)
      let answer = row(
        TranscriptFixture.answer("a1", "## Step\n\nA paragraph with `code`.\n\n- one\n- two"))
      for width in [Self.width, 600] {
        cell.show(answer, version: 0, width: width)
        let text = try #require(cell.texts.first)
        let metrics = TranscriptTableTextMetrics(
          width: width, layoutWidth: .regular, maxWidth: Theme.transcriptWidth)
        let measured = text.measurement(for: metrics.columnWidth)
        #expect(text.frame.minX == metrics.columnX)
        #expect(text.frame.width == metrics.columnWidth)
        #expect(
          cell.idealHeight
            == (measured.height + Theme.Spacing.small + Theme.Spacing.row).rounded(.up))
      }
      // Each width laid out once; showing it again lays out nothing.
      let passes = try #require(cell.texts.first).layoutPasses
      cell.show(answer, version: 0, width: 600)
      #expect(try #require(cell.texts.first).layoutPasses == passes)
    }

    @Test("With runs drawn ahead, a cell shows the drawing at its height, no live text view")
    func rasterCell() throws {
      let style = textStyle()
      style.surface = .raster
      style.setScale(2)
      let answer = row(TranscriptFixture.answer("a-drawn", "Drawn ahead.\n\n- one\n- two"))
      let message = try #require(TranscriptTableTextMessage.make(answer, ramp: style.ramp))
      let run = try #require(message.runs.first)
      let document = MessageTextBlocksView.document(
        source: MessageTextSource(text: message.markdown, piece: run.id), blocks: run.blocks,
        linked: [], style: try #require(style.style), links: nil)
      let width = TranscriptTableTextMetrics(
        width: Self.width, layoutWidth: .regular, maxWidth: Theme.transcriptWidth
      ).columnWidth
      let drawn = MessageTextRaster.make(
        document.run, width: width, scale: 2, style: try #require(style.rasterStyle))
      MessageTextRasters.shared.store(
        drawn, for: MessageTextRasterKey(document: document.serial, width: width, scale: 2))
      let cell = TranscriptTableTextCell(style: style)
      cell.show(answer, version: 0, width: Self.width)
      #expect(cell.texts.isEmpty)
      guard case .raster(let view)? = cell.runs.first else {
        Issue.record("the run shows live")
        return
      }
      #expect(view.raster === drawn)
      #expect(
        cell.idealHeight
          == (drawn.size.height + Theme.Spacing.small + Theme.Spacing.row).rounded(.up))
    }

    @Test("A user's prompt hugs its text in a bubble at the column's trailing edge")
    func promptSizing() throws {
      let cell = TranscriptTableTextCell(style: textStyle())
      cell.show(row(TranscriptFixture.user("u1", "Short?")), version: 0, width: Self.width)
      let text = try #require(cell.texts.first)
      let metrics = TranscriptTableTextMetrics(
        width: Self.width, layoutWidth: .regular, maxWidth: Theme.transcriptWidth)
      let bubble = try #require(cell.subviews.first { $0 is TranscriptTableBubbleView })
      #expect(abs(bubble.frame.maxX - (metrics.columnX + metrics.columnWidth)) < 0.5)
      #expect(text.frame.width < metrics.promptWidth(.regular) / 2)
      #expect(bubble.frame.width == text.frame.width + 2 * Theme.Spacing.large)
      #expect(
        cell.idealHeight
          == (bubble.frame.height + Theme.Spacing.extraSmall + Theme.Spacing.row).rounded(.up))
    }

    @Test("Settled messages take text cells, measured by TextKit; other rows stay hosted")
    func cellKinds() async throws {
      var streaming = TranscriptFixture.answer("a-live", "Streaming", responseID: "r-live")
      streaming.isStreaming = true
      let rows = [
        TranscriptFixture.user("u1", "Short?"),
        TranscriptFixture.answer("a1", "Yes.\n\n- one\n- two", responseID: "r1"),
        TranscriptFixture.answer("a-diagram", Self.diagram, responseID: "r-diagram"),
        streaming,
      ]
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let window = transcriptScreen(
        Host(conversation: conversation), width: Self.width, height: 900)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      let expected: [String: TranscriptTableCellKind] = [
        "u1": .text(.userMessage), "a1": .text(.answer),
        "a-diagram": .hosted(.answer), "a-live": .hosted(.answer),
        TranscriptTableRow.footerID: .hosted(.footer),
      ]
      for (id, kind) in expected {
        let index = try #require(controller.model.index(of: id))
        #expect(controller.cellKind(at: index) == kind, "\(id)")
        let cell = try #require(controller.realizedCell(at: index), "\(id) is on screen")
        #expect(cell.kind == kind, "\(id)")
        // The table lays the row out at the height its cell measured.
        #expect(controller.model.height(at: index) == cell.idealHeight, "\(id)")
      }
    }

    @Test("A scroll hands the answers past its lookahead to the prewarm, nearest first")
    func prewarmAhead() async throws {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(30)))
      let window = transcriptScreen(Host(conversation: conversation), width: Self.width)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      let top = driver.offset
      let viewport = try #require(driver.scrollView).contentView.bounds.height
      driver.move(to: top - 200)
      // The rows from the viewport's top up through the lookahead and the prewarm's reach.
      let reach = viewport * (TranscriptTableController.lookahead + 2)
      let ahead = table.rows(in: NSRect(x: 0, y: top - 200 - reach, width: 10, height: reach))
      let answers = (ahead.location..<(ahead.location + ahead.length)).filter {
        controller.model.rows[$0].kind == .answer
      }
      #expect(answers.count >= 2)
      for index in answers {
        #expect(controller.prewarmed[controller.model.rows[index].id] != nil, "row \(index)")
      }
    }

    @Test("Prioritized answers go to the front of the queue in order, once each")
    func prioritizeOrder() {
      let prewarm = MessageTextPrewarm(limit: 3)
      prewarm.prioritize(["a", "b"])
      prewarm.prioritize(["c", "b"])
      #expect(prewarm.pendingTexts == ["c", "b", "a"])
      prewarm.prioritize(["d"])
      #expect(prewarm.pendingTexts == ["d", "c", "b"])
    }

    @Test("A parked cell goes back to its row only as the same kind of cell")
    func poolByKind() {
      let style = textStyle()
      var pool = TranscriptTableCellPool()
      let text = TranscriptTableTextCell(style: style)
      text.show(row(TranscriptFixture.answer("a1")), version: 0, width: Self.width)
      pool.park(text)
      #expect(pool.take(id: "a1", kind: .text(.answer)) === text)
      pool.park(text)
      // The row now shows hosted (it streams again, say): its text cell becomes a spare.
      #expect(pool.take(id: "a1", kind: .hosted(.answer)) == nil)
      #expect(pool.take(id: "a2", kind: .text(.answer)) === text)
      #expect(pool.take(id: "a3", kind: .text(.userMessage)) == nil)
    }
  }
#endif
