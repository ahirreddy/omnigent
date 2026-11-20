#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Trackpad and wheel scrolls over a transcript's blocks that scroll sideways. A gesture belongs
  /// to the scroller it began over, so the transcript keeps scrolling as such a block passes under
  /// the pointer, and the block takes only a sideways gesture that began over it.
  @Suite("Scrolls over a transcript's sideways blocks", .serialized)
  @MainActor
  struct TranscriptInnerScrollTests {
    /// A block that scrolls sideways: a CLI table drawn as TextKit text in a copy that scrolls,
    /// and a chat table too wide to draw as text, hosted in SwiftUI.
    enum Block: String, CaseIterable, Sendable {
      case cliTable
      case chatTable
    }

    init() {
      SystemSideEffects.reset()
    }

    private struct Host: View {
      let conversation: LiveConversation
      let style: TranscriptStyle

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: ConversationActions(),
          scrollToLatestRequest: conversation.scrollRequest
        )
        .environment(\.messageTextRenderer, .textKit)
        .transcriptAppearance(TranscriptAppearance(style: style))
      }
    }

    /// A table of `columns` columns, each cell `cell` wide in words.
    private static func table(columns: Int, cell: String) -> String {
      let header = (0..<columns).map { "Column \($0)" }.joined(separator: " | ")
      let cells = (0..<columns).map { "\(cell) \($0)" }.joined(separator: " | ")
      let rule = Array(repeating: " --- |", count: columns).joined()
      return "| \(header) |\n|\(rule)\n| \(cells) |\n| \(cells) |\n| \(cells) |"
    }

    /// The transcript in a window, turns around an answer holding `block`, the block in the
    /// middle of the viewport.
    private struct Screen {
      let window: OffscreenWindow<AnyView>
      let transcript: NSScrollView
      let controller: TranscriptTableController
      let block: NSScrollView

      /// The events the transcript took to scroll for: its controller counts each as the reader
      /// scrolling. Offscreen, AppKit's scroll views don't move for made-up events, so the tests
      /// check which scroller took them.
      var transcriptSteps: Int { controller.wheelSteps }

      /// The middle of the block, where it shows, in window coordinates.
      var overBlock: CGPoint {
        let shown = block.convert(block.visibleRect, to: nil)
        return CGPoint(x: shown.midX, y: shown.midY)
      }

      /// A point in the transcript's rows away from the block, in window coordinates: left of
      /// the middle, clear of Jump to latest.
      var besideBlock: CGPoint {
        let viewport = transcript.convert(transcript.bounds, to: nil)
        let shown = block.convert(block.visibleRect, to: nil)
        let left = viewport.minX + viewport.width * 0.3
        // Window coordinates grow upward: the viewport's top is its largest y.
        let top = CGPoint(x: left, y: viewport.maxY - 80)
        let bottom = CGPoint(x: left, y: viewport.minY + 120)
        return shown.maxY < top.y - 20 ? top : bottom
      }
    }

    private func openScreen(_ block: Block) async throws -> Screen {
      let wide: String
      let style: TranscriptStyle
      switch block {
      case .cliTable:
        wide = Self.table(columns: 9, cell: "value of a row")
        style = .cli
      case .chatTable:
        wide = Self.table(columns: 8, cell: "a longer value of a row")
        style = .chat
      }
      var rows = TranscriptFixture.turns(4, startingAt: 10)
      rows += [
        TranscriptFixture.user("u-wide", "Show it as a table"),
        TranscriptFixture.answer(
          "a-wide", "Here it is.\n\n\(wide)\n\nThat's all.", responseID: "r-w"),
      ]
      rows += TranscriptFixture.turns(4, startingAt: 20)
      let conversation = LiveConversation(
        ConversationViewState(header: TranscriptFixture.header, rows: rows))
      let window = transcriptScreen(
        Host(conversation: conversation, style: style), width: 900, height: 700)
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let transcript = try #require(driver.scrollView)
      let controller = try #require(driver.tableController)
      let row = try #require(controller.model.index(of: "a-wide"))
      func inner() -> NSScrollView? {
        window.allViews.lazy.compactMap { $0 as? NSScrollView }.first {
          guard $0 !== transcript, $0.isDescendant(of: transcript), let document = $0.documentView
          else { return false }
          return document.frame.width > $0.contentView.bounds.width + 50
        }
      }
      // Rows measure as they come into view, and a table's copy comes once its text is laid out.
      for _ in 0..<3 {
        let frame = controller.tableView.rect(ofRow: row)
        driver.move(to: frame.midY - transcript.contentView.bounds.height / 2)
        if await MainLoop.waitUntil(timeout: .seconds(2), { inner() != nil }) { break }
      }
      window.settle(0.2)
      let found = try #require(inner(), "the wide table scrolls sideways in its own view")
      let screen = Screen(
        window: window, transcript: transcript, controller: controller, block: found)
      #expect(try view(under: screen.overBlock, in: window).isDescendant(of: found))
      let beside = try view(under: screen.besideBlock, in: window)
      #expect(beside.isDescendant(of: transcript) && !beside.isDescendant(of: found))
      // A live scroll would count no steps; these events start none offscreen.
      #expect(!controller.isLiveScrolling)
      return screen
    }

    /// The view AppKit sends a scroll at `point`, in window coordinates, to.
    private func view(under point: CGPoint, in window: OffscreenWindow<AnyView>) throws -> NSView {
      let content = try #require(window.window.contentView)
      // AppKit declares `superview` unowned(unsafe); it is only read here.
      let local = unsafe content.superview?.convert(point, from: nil) ?? point
      return try #require(content.hitTest(local))
    }

    /// One wheel or trackpad event, at a point in window coordinates.
    private struct Step {
      var phase: CGScrollPhase?
      var momentum = CGMomentumScrollPhase.none
      var across: Int32 = 0
      var down: Int32 = 0
      var point: CGPoint
    }

    /// Sends each step to the view under its point, as AppKit sends a scroll to the view under
    /// the pointer, wherever the gesture began.
    private func perform(_ steps: [Step], on screen: Screen) throws {
      for step in steps {
        let event = try #require(
          CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: step.down,
            wheel2: step.across, wheel3: 0))
        event.setIntegerValueField(
          .scrollWheelEventScrollPhase, value: Int64(step.phase?.rawValue ?? 0))
        event.setIntegerValueField(
          .scrollWheelEventMomentumPhase, value: Int64(step.momentum.rawValue))
        let global = screen.window.window.convertPoint(toScreen: step.point)
        let displayHeight = NSScreen.screens.first?.frame.height ?? 0
        event.location = CGPoint(x: global.x, y: displayHeight - global.y)
        let scroll = try #require(NSEvent(cgEvent: event))
        try view(under: step.point, in: screen.window).scrollWheel(with: scroll)
      }
      screen.window.settle(0.05)
    }

    /// A gesture's touching part: it begins at `start` and moves `moves` times at `over`.
    private func touch(
      at start: CGPoint, then over: CGPoint, moves: Int = 3, across: Int32 = 0, down: Int32 = 0
    ) -> [Step] {
      [Step(phase: .began, across: across, down: down, point: start)]
        + (0..<moves).map { _ in Step(phase: .changed, across: across, down: down, point: over) }
        + [Step(phase: .ended, point: over)]
    }

    /// A gesture's momentum after its lift, at `point`.
    private func coast(
      at point: CGPoint, moves: Int = 3, across: Int32 = 0, down: Int32 = 0
    ) -> [Step] {
      [Step(phase: nil, momentum: .begin, across: across, down: down, point: point)]
        + (0..<moves).map { _ in
          Step(phase: nil, momentum: .continuous, across: across, down: down, point: point)
        }
        + [Step(phase: nil, momentum: .end, point: point)]
    }

    @Test(
      "A scroll up that began beside the block goes on scrolling the transcript over it",
      arguments: Block.allCases)
    func passesOver(_ block: Block) async throws {
      let screen = try await openScreen(block)
      defer { screen.window.close() }
      let start = screen.transcriptSteps
      try perform(touch(at: screen.besideBlock, then: screen.overBlock, down: 30), on: screen)
      #expect(screen.transcriptSteps - start == 5, "began, three moves and the lift")
    }

    @Test(
      "A vertical scroll that begins over the block scrolls the transcript",
      arguments: Block.allCases)
    func verticalOver(_ block: Block) async throws {
      let screen = try await openScreen(block)
      defer { screen.window.close() }
      let start = screen.transcriptSteps
      try perform(touch(at: screen.overBlock, then: screen.overBlock, down: 30), on: screen)
      #expect(screen.transcriptSteps - start == 5, "began, three moves and the lift")
    }

    @Test("A sideways scroll over the block leaves the transcript alone", arguments: Block.allCases)
    func sidewaysOver(_ block: Block) async throws {
      let screen = try await openScreen(block)
      defer { screen.window.close() }
      let start = screen.transcriptSteps
      try perform(touch(at: screen.overBlock, then: screen.overBlock, across: -30), on: screen)
      try perform(coast(at: screen.overBlock, across: -30), on: screen)
      #expect(screen.transcriptSteps == start)
    }

    @Test(
      "Momentum from a scroll that began beside the block carries the transcript over it",
      arguments: Block.allCases)
    func momentumOver(_ block: Block) async throws {
      let screen = try await openScreen(block)
      defer { screen.window.close() }
      try perform(touch(at: screen.besideBlock, then: screen.besideBlock, down: 30), on: screen)
      let lifted = screen.transcriptSteps
      try perform(coast(at: screen.overBlock, down: 30), on: screen)
      #expect(screen.transcriptSteps - lifted == 5, "momentum's start, three moves and its end")
    }

    @Test("A mouse wheel over the block scrolls the transcript", arguments: Block.allCases)
    func wheelOver(_ block: Block) async throws {
      let screen = try await openScreen(block)
      defer { screen.window.close() }
      let start = screen.transcriptSteps
      let point = screen.overBlock
      try perform(Array(repeating: Step(down: 30, point: point), count: 3), on: screen)
      #expect(screen.transcriptSteps - start == 3)
    }
  }
#endif
