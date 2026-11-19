#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// CLI-style rows in the table transcript drawn as TextKit text in AppKit cells: which rows
  /// they take, their heights beside the SwiftUI rows they replace, and their drawings.
  @Suite("Transcript table CLI text cells", .serialized)
  @MainActor
  struct TranscriptTableCLICellTests {
    static let width: CGFloat = 900

    init() {
      SystemSideEffects.reset()
    }

    struct Host: View {
      let conversation: LiveConversation
      var rendering: OutputRendering = .styled

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: ConversationActions(),
          scrollToLatestRequest: conversation.scrollRequest
        )
        .environment(\.messageTextRenderer, .textKit)
        .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering))
      }
    }

    /// The table's environment in CLI style with TextKit chosen.
    func environment(rendering: OutputRendering = .styled) -> TranscriptTableEnvironment {
      let environment = TranscriptTableEnvironment()
      var values = EnvironmentValues()
      values.messageTextRenderer = .textKit
      values.transcriptAppearance = TranscriptAppearance(style: .cli, outputRendering: rendering)
      values.cliPalette = .fallback
      values.layoutWidth = .regular
      environment.values = values
      return environment
    }

    func style(_ environment: TranscriptTableEnvironment) -> TranscriptTableCLIStyle {
      let style = TranscriptTableCLIStyle(
        environment: environment, textStyle: TranscriptTableTextStyle(environment: environment),
        setting: .text)
      style.refresh()
      return style
    }

    func row(_ block: CLIBlock, decorations: [String: MessageDecoration] = [:])
      -> TranscriptTableRow
    {
      TranscriptTableRow(.block(CLIBlockEntry(block: block, decorations: decorations)))
    }

    func message(_ row: Row) -> TranscriptTableRow {
      self.row(.segment(.item(.message(row))))
    }

    /// An answer shaped like the long transcript's (seed-large-fixtures.py).
    private static let answer = """
      ## Step 12: caching

      The handler calls `process(batch:)` once per item, which is quadratic for large batches; \
      see [the design note](https://example.com/design) for the background.

      - Moved the parsing out of the hot loop
        - nested detail with *emphasis*
      - Added a regression test

      ```swift
      struct Model12: Codable, Hashable {
        var field0: [String: Int] = ["key0": 0]
        var field1: [String: Int] = ["key1": 12]
      }
      ```

      | Step | Owner | Status |
      | --- | :---: | ---: |
      | 1 | team-0 | done |
      | 2 | team-1 | blocked |

      - [x] reproduce
      - [ ] ship the release

      > Note: this is seeded profiling data, not a real answer.
      """

    @Test("A CLI row's height is the SwiftUI row's", arguments: [OutputRendering.styled, .plain])
    func heights(rendering: OutputRendering) throws {
      let environment = environment(rendering: rendering)
      let style = style(environment)
      #expect(style.isEnabled)
      let rows =
        [
          message(TranscriptFixture.user("u1", "Short?")),
          message(TranscriptFixture.user("u2", "> It said this\nMy reply to it")),
          message(TranscriptFixture.questionReply("u3")),
          message(TranscriptFixture.answer("a1", Self.answer)),
          message(TranscriptFixture.answer("a2", "## Step\n\nA paragraph with `code`.\n\n- one")),
          row(.footer(id: "a1", text: "Worked for 12s \u{2022} 9:47 PM")),
        ] + workRows
      for row in rows {
        let cell = TranscriptTableCLICell(style: style)
        cell.show(row, version: 0, width: Self.width)
        #expect(cell.kind == .cliText(row.kind), "\(row.id)")
        let hosted = TranscriptTableHostingCell.make(environment: environment)
        hosted.show(row, version: 0, width: Self.width)
        #expect(
          abs(cell.idealHeight - hosted.idealHeight) < 0.5,
          "\(row.id): text \(cell.idealHeight), SwiftUI \(hosted.idealHeight)")
      }
    }

    @Test("The text sits on the CLI column, its marker in the gutter, a prompt in its band")
    func placement() throws {
      let style = style(environment())
      let cell = TranscriptTableCLICell(style: style)
      cell.show(message(TranscriptFixture.user("u1", "Short?")), version: 0, width: Self.width)
      let column = style.column(width: Self.width)
      let gutter = max(
        CLIMetrics.gutter,
        13 * CLIFontSize.characterRatio * CGFloat(CLIMetrics.markerColumns)
          + Theme.Spacing.extraSmall)
      #expect(abs(column.leading - (gutter + TurnRail.restingEdge)) < 0.5)
      #expect(abs(column.width - (Self.width - 2 * gutter - TurnRail.restingEdge)) < 0.01)
      let text = try #require(cell.run?.view)
      #expect(text.frame.minX == column.leading)
      #expect(text.frame.minY == CLIMetrics.bandPadding)
      #expect(!cell.band.isHidden)
      #expect(cell.band.frame.width == Self.width)
      #expect(cell.band.frame.height == text.frame.height + 2 * CLIMetrics.bandPadding)
    }

    @Test("With texts drawn ahead, a cell shows the drawing, and a press lays live text over it")
    func rasterAndLive() throws {
      let style = style(environment())
      style.textStyle.surface = .raster
      style.textStyle.refresh()
      style.textStyle.setScale(2)
      #expect(style.drawsAhead)
      let cell = TranscriptTableCLICell(style: style)
      cell.show(
        message(TranscriptFixture.answer("a1", "Short answer.")), version: 0, width: Self.width)
      guard case .raster(let view)? = cell.run else {
        Issue.record("the text shows live")
        return
      }
      #expect(view.raster.size.height > 0)
      // A press lays a live text view over the drawing: its text is the selectable kind the
      // selection popup's Reply reads.
      let live = view.activate()
      #expect(live.textView.string == "Short answer.")
      live.textView.setSelectedRange(NSRange(location: 0, length: 5))
      #expect(live.textView.copiedSelection == "Short")
      // Off screen the cell lets the bitmap go; shown again, it takes the cached one back.
      view.deactivate()
      cell.releaseBitmaps()
      #expect(view.isReleased)
      cell.show(
        message(TranscriptFixture.answer("a1", "Short answer.")), version: 0, width: Self.width)
      #expect(!view.isReleased)
    }

    /// A table of `columns` columns, then a line after it.
    private static func table(columns: Int) -> String {
      let header = (0..<columns).map { "Column \($0)" }.joined(separator: " | ")
      let cells = (0..<columns).map { "value \($0) of a row" }.joined(separator: " | ")
      let rule = Array(repeating: " --- |", count: columns).joined()
      return "| \(header) |\n|\(rule)\n| \(cells) |\n| \(cells) |\n\nAfter the table."
    }

    @Test("A table wider than the column scrolls sideways over its unseen rows, as SwiftUI's does")
    func wideTable() throws {
      let environment = environment()
      let style = style(environment)
      let row = message(TranscriptFixture.answer("a1", Self.table(columns: 9)))
      let cell = TranscriptTableCLICell(style: style)
      cell.show(row, version: 0, width: Self.width)
      #expect(cell.overflowViews.count == 1)
      let overflow = try #require(cell.overflowViews.first)
      // The copy spans the column and scrolls its rows past it, their rules with them.
      #expect(overflow.frame.minX == cell.textFrame.minX)
      #expect(abs(overflow.frame.maxX - cell.textFrame.maxX) < 0.5)
      #expect(overflow.contentWidth > overflow.frame.width + 100)
      #expect(overflow.textView.string.contains("value 8 of a row"))
      let rules = overflow.textView.subviews.compactMap { $0 as? TranscriptTableCLIDecorationsView }
      #expect(rules.first?.shown.isEmpty == false)
      overflow.contentView.scroll(to: NSPoint(x: 120, y: 0))
      #expect(overflow.contentView.bounds.minX == 120)
      // The text keeps the rows' lines unseen, so the row is as tall as SwiftUI's; what follows
      // the table shows.
      let text = try #require(cell.document).text.text
      func alpha(of words: String) -> CGFloat? {
        guard let found = text.string.range(of: words) else { return nil }
        let location = NSRange(found, in: text.string).location
        // Nothing reads the effective range back.
        let color = unsafe text.attribute(.foregroundColor, at: location, effectiveRange: nil)
        return (color as? NSColor)?.alphaComponent
      }
      #expect(alpha(of: "value 8 of a row") == 0)
      #expect((alpha(of: "After the table.") ?? 0) > 0)
      let hosted = TranscriptTableHostingCell.make(environment: environment)
      hosted.show(row, version: 0, width: Self.width)
      #expect(abs(cell.idealHeight - hosted.idealHeight) < 0.5)

      // A table that fits needs no copy.
      cell.show(
        message(TranscriptFixture.answer("a2", Self.table(columns: 2))), version: 0,
        width: Self.width)
      #expect(cell.overflowViews.isEmpty)
      // AppKit declares `superview` unowned(unsafe); it is only read here.
      #expect(unsafe overflow.superview == nil)
    }

    @Test("Settled CLI messages, footers and tool work take CLI text cells; streams stay hosted")
    func cellKinds() async throws {
      var streaming = TranscriptFixture.answer("a-live", "Streaming", responseID: "r-live")
      streaming.isStreaming = true
      let rows = [
        TranscriptFixture.user("u1", "Short?"),
        TranscriptFixture.toolCall("call-1"),
        TranscriptFixture.toolResult("result-1", callID: "call-1"),
        TranscriptFixture.answer("a1", "Yes.\n\n- one\n- two", responseID: "resp-1"),
        TranscriptFixture.user("u2", "And?"),
        streaming,
      ]
      var state = ConversationViewState(header: TranscriptFixture.header, rows: rows)
      // The settled turn's footer reads its duration.
      state.turnDurations = ["resp-1": 12]
      let conversation = LiveConversation(state)
      let window = transcriptScreen(
        Host(conversation: conversation), width: Self.width, height: 900)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      var kinds: [String: TranscriptTableCellKind] = [:]
      for index in controller.model.rows.indices {
        kinds[controller.model.rows[index].id] = controller.cellKind(at: index)
      }
      #expect(kinds["u1"] == .cliText(.userMessage))
      #expect(kinds["a1"] == .cliText(.answer))
      #expect(kinds["u2"] == .cliText(.userMessage))
      #expect(kinds["a-live"] == .hosted(.answer))
      let footer = kinds.first { $0.key.hasPrefix("footer:") }
      #expect(footer?.value == .cliText(.cliFooter))
      #expect(kinds.values.contains(.cliText(.worked)))
      for index in controller.model.rows.indices {
        guard case .cliText = kinds[controller.model.rows[index].id],
          let cell = controller.realizedCell(at: index)
        else { continue }
        #expect(cell is TranscriptTableCLICell)
        // The table lays the row out at the height its cell measured.
        #expect(controller.model.height(at: index) == cell.idealHeight)
      }
    }

    @Test("Rich rendering and the hosted setting keep CLI rows SwiftUI's")
    func disabled() throws {
      #expect(!style(environment(rendering: .rich)).isEnabled)
      let environment = environment()
      let hosted = TranscriptTableCLIStyle(
        environment: environment, textStyle: TranscriptTableTextStyle(environment: environment),
        setting: .hosted)
      hosted.refresh()
      #expect(!hosted.isEnabled)
      let defaults = try #require(UserDefaults(suiteName: "cli-text-unset"))
      #expect(TranscriptTableCLITextSetting(defaults: defaults) == .text)
    }

    @Test("A prewarmed CLI text is built off the main actor and found by the cell")
    func prewarm() async throws {
      let environment = environment()
      let style = style(environment)
      let column = style.column(width: Self.width)
      let context = try #require(style.prewarmContext(width: column.width))
      let prewarm = CLITextPrewarm(limit: 8)
      prewarm.note(context)
      let spec = CLITextSpec.styled("Built ahead, **off** the main actor.")
      #expect(CLITextSpec(key: spec.key) == spec)
      prewarm.prioritize([spec], at: [0])
      let deadline = Date().addingTimeInterval(5)
      while style.builtDocument(for: spec, width: column.width) == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(style.builtDocument(for: spec, width: column.width) != nil)
    }
  }

  // MARK: Question replies

  extension TranscriptTableCLICellTests {
    @Test("A reply to an agent's questions draws each answer under its dim quoted question")
    func questionReply() throws {
      let cell = TranscriptTableCLICell(style: style(environment()))
      cell.show(message(TranscriptFixture.questionReply("u-reply")), version: 0, width: Self.width)
      #expect(cell.kind == .cliText(.userMessage))
      let text = try #require(cell.document).text.text
      #expect(text.string == "\u{21AA} Re: Color?\nBlue\nLarge")
      func color(of words: String) throws -> NSColor? {
        let found = try #require(text.string.range(of: words))
        let location = NSRange(found, in: text.string).location
        // Nothing reads the effective range back.
        return unsafe text.attribute(.foregroundColor, at: location, effectiveRange: nil)
          as? NSColor
      }
      let palette = CLIPalette.fallback
      #expect(try color(of: "\u{21AA} Re: Color?") == palette.dim.platformColor)
      #expect(try color(of: "Blue") == palette.userText.platformColor)
      #expect(try color(of: "Large") == palette.userText.platformColor)
    }
  }
#endif
