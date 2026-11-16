#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The table transcript in a window: what it measures, and where it keeps the reader as rows
  /// grow, arrive and page in above.
  @Suite("Transcript table scrolling", .serialized)
  @MainActor
  struct TranscriptTableScrollingTests {
    static let width: CGFloat = 900
    static let height: CGFloat = 500
    let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private struct Host: View {
      let conversation: LiveConversation
      let actions: ConversationActions

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: nil, actions: actions,
          scrollToLatestRequest: conversation.scrollRequest)
      }
    }

    private var pagingActions: ConversationActions {
      var actions = ConversationActions()
      let log = self.log
      actions.loadOlder = { log.add("older") }
      return actions
    }

    /// `turns` turns, then a short one that fits the window.
    private func session(turns: Int = 10, hasMore: Bool = false) -> LiveConversation {
      var rows = TranscriptFixture.turns(turns, startingAt: 10)
      rows += [
        TranscriptFixture.user("u-last", "Short?"),
        TranscriptFixture.answer("a-last", "Yes.", responseID: "r-last"),
      ]
      var state = ConversationViewState(header: TranscriptFixture.header, rows: rows)
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    /// The transcript in a window, its scroll driver (whose `screen` is the window) and the
    /// table's controller.
    private func screen(
      _ conversation: LiveConversation, actions: ConversationActions = ConversationActions()
    ) async throws -> (TranscriptScrollDriver, TranscriptTableController) {
      let window = transcriptScreen(
        Host(conversation: conversation, actions: actions), width: Self.width,
        height: Self.height)
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      return (driver, controller)
    }

    /// Lets idle measuring run: it starts once the reader has been still a while.
    private func rest(_ window: OffscreenWindow<AnyView>) {
      window.run(for: TranscriptTableController.prefetchDelay + 0.3)
    }

    /// Moves the viewport to `offset` as a reader's trackpad scroll does.
    private func scroll(
      _ window: OffscreenWindow<AnyView>, _ driver: TranscriptScrollDriver, to offset: CGFloat
    ) throws {
      let scrollView = try #require(driver.scrollView)
      window.liveScroll(scrollView, began: true)
      driver.move(to: offset)
      window.liveScroll(scrollView, began: false)
    }

    private func isAtEnd(_ driver: TranscriptScrollDriver) -> Bool {
      abs(driver.offset - driver.maximumOffset) < 1
    }

    /// Whether the same point of the same row is under the viewport's top.
    private func isReading(
      _ anchor: TranscriptTableController.ReadingAnchor, _ controller: TranscriptTableController
    ) -> Bool {
      guard let now = controller.readingAnchor() else { return false }
      return now.id == anchor.id && abs(now.offset - anchor.offset) < 1
    }

    @Test("Opening at a turn that fits follows the end, and a streamed reply keeps it in view")
    func followsStreaming() async throws {
      let conversation = session()
      let (driver, controller) = try await screen(conversation)
      let window = driver.screen
      defer { window.close() }
      #expect(isAtEnd(driver))
      #expect(controller.follow.follows)
      var reply = "First"
      for step in 0..<6 {
        reply += "\n\nParagraph \(step) of a reply that keeps growing while it streams in."
        conversation.stream("streamed", reply)
        window.settle(0.05)
        #expect(isAtEnd(driver), "step \(step): \(driver.offset) of \(driver.maximumOffset)")
      }
      let row = try #require(controller.model.index(of: "streamed"))
      #expect(!controller.model.needsMeasure(at: row))
    }

    @Test("A reader who scrolled up stays put while output arrives; Jump to latest goes back")
    func readerStaysPut() async throws {
      let conversation = session()
      let (driver, controller) = try await screen(conversation)
      let window = driver.screen
      defer { window.close() }
      try scroll(window, driver, to: driver.offset - 600)
      #expect(!controller.follow.follows)
      let anchor = try #require(controller.readingAnchor())
      let offset = driver.offset
      conversation.stream("streamed", "A reply\n\nwith\n\nseveral\n\nparagraphs")
      window.settle(0.1)
      conversation.append(TranscriptFixture.user("u-next", "And then?"))
      window.settle(0.1)
      #expect(abs(driver.offset - offset) < 1)
      #expect(isReading(anchor, controller))
      #expect(controller.follow.pill.isShown)
      controller.jumpToLatest()
      window.settle()
      #expect(isAtEnd(driver))
      #expect(controller.follow.follows)
    }

    @Test("Older rows landing above keep the reader on the row they were reading")
    func pagingKeepsPosition() async throws {
      let conversation = session(hasMore: true)
      let (driver, controller) = try await screen(conversation, actions: pagingActions)
      let window = driver.screen
      defer { window.close() }
      try scroll(window, driver, to: 120)
      #expect(log.entries.contains("older"))
      let anchor = try #require(controller.readingAnchor())
      conversation.state.isLoadingHistory = true
      window.settle()
      #expect(isReading(anchor, controller))
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(4), at: 0)
      conversation.state.revision += 1
      conversation.state.isLoadingHistory = false
      conversation.state.historyReads += 1
      window.settle()
      #expect(isReading(anchor, controller))
      #expect(driver.offset > 400)
      // The new rows are measured as the reader scrolls up into them, and the row read stays.
      rest(window)
      #expect(isReading(anchor, controller))
    }

    @Test("Rows are measured once: scrolling back over them and a streamed delta measure little")
    func measuresOnce() async throws {
      let conversation = session(turns: 24)
      let (driver, controller) = try await screen(conversation)
      let window = driver.screen
      defer { window.close() }
      // Idle measuring reaches the rows a few viewports around the reader, and stops short of
      // the rest; its reach is judged by where rows were before it measured them.
      rest(window)
      let shown = try #require(driver.scrollView).contentView.bounds
      let reach = shown.insetBy(
        dx: 0, dy: -shown.height * TranscriptTableController.prefetchReach)
      var unmeasuredBeyond = 0
      for index in controller.model.rows.indices {
        let rect = controller.tableView.rect(ofRow: index)
        if rect.minY >= reach.minY, rect.maxY <= reach.maxY {
          #expect(!controller.model.needsMeasure(at: index), "row \(index)")
        } else if rect.maxY < reach.minY, controller.model.needsMeasure(at: index) {
          unmeasuredBeyond += 1
        }
      }
      #expect(unmeasuredBeyond > 0)
      let end = driver.offset
      let measured = controller.measurements
      for step in 1...6 { try scroll(window, driver, to: end - CGFloat(step) * 150) }
      for step in 1...6 { try scroll(window, driver, to: end - 900 + CGFloat(step) * 150) }
      #expect(controller.measurements == measured)
      controller.jumpToLatest()
      conversation.stream("streamed", "One line")
      window.settle(0.05)
      conversation.stream("streamed", "One line\n\nand another")
      window.settle(0.05)
      // The streamed row each time, and the footer once its working line goes.
      #expect(controller.measurements - measured <= 4)
      #expect(isAtEnd(driver))
    }
  }
#endif
