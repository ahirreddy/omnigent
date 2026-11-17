#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
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

    /// With `rows`, the table reads its rows from them, as the app's does.
    private struct Host: View {
      let conversation: LiveConversation
      let actions: ConversationActions
      var rows: LiveTranscriptRows?
      var renderer = MessageTextRenderer.swiftUI

      var body: some View {
        TableTranscriptView(
          state: conversation.state, liveRows: rows, actions: actions,
          scrollToLatestRequest: conversation.scrollRequest
        )
        .environment(\.messageTextRenderer, renderer)
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
      _ conversation: LiveConversation, rows: LiveRowsSource? = nil,
      actions: ConversationActions = ConversationActions(), focus: TranscriptFocus? = nil,
      renderer: MessageTextRenderer = .swiftUI
    ) async throws -> (TranscriptScrollDriver, TranscriptTableController) {
      let window = transcriptScreen(
        Host(conversation: conversation, actions: actions, rows: rows?.reader, renderer: renderer)
          .environment(\.transcriptFocus, focus),
        width: Self.width, height: Self.height)
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

    /// Whether row `id` is in the viewport.
    private func shows(_ id: String, _ controller: TranscriptTableController) -> Bool {
      guard let index = controller.model.index(of: id) else { return false }
      return controller.tableView.rect(ofRow: index).intersects(controller.clipView.bounds)
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

    @Test("Leaving the end shows Jump to latest and coming back hides it, rendering no rows")
    func pillAlone() async throws {
      let (driver, controller) = try await screen(session())
      let window = driver.screen
      defer { window.close() }
      let scrollView = try #require(driver.scrollView)
      let end = driver.offset
      var showed = false
      let renders = RenderTally.recording {
        window.liveScroll(scrollView, began: true)
        driver.move(to: end - 300)
        window.liveScroll(scrollView, began: false)
        window.settle()
        showed = (try? window.shows("Jump to latest")) ?? false
        window.liveScroll(scrollView, began: true)
        driver.move(to: end)
        window.liveScroll(scrollView, began: false)
        window.settle()
      }
      #expect(showed)
      #expect(!controller.follow.pill.isShown)
      #expect(try !window.shows("Jump to latest"))
      // The pill is the only view that reads it: not the transcript, nor its rows.
      #expect(renders["transcript", default: 0] == 0, "\(renders)")
      #expect(renders["rows", default: 0] == 0, "\(renders)")
    }

    @Test(
      "Older rows landing above keep the reader on the row they were reading",
      arguments: [MessageTextRenderer.swiftUI, .textKit])
    func pagingKeepsPosition(_ renderer: MessageTextRenderer) async throws {
      let conversation = session(hasMore: true)
      let (driver, controller) = try await screen(
        conversation, actions: pagingActions, renderer: renderer)
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

    @Test("A page landing above a reader at the top keeps the rows they were reading in place")
    func pagingAtTheTopKeepsPosition() async throws {
      let conversation = session(hasMore: true)
      let (driver, controller) = try await screen(conversation, actions: pagingActions)
      let window = driver.screen
      defer { window.close() }
      try scroll(window, driver, to: controller.minimumOffset)
      let first = try #require(controller.model.rows.dropFirst().first?.id)
      conversation.state.isLoadingHistory = true
      window.settle()
      // Where the first row is under the header's loading line, as the reader last sees it.
      let below = controller.tableView.rect(ofRow: 1).minY - driver.offset
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(4), at: 0)
      conversation.state.revision += 1
      conversation.state.isLoadingHistory = false
      conversation.state.historyReads += 1
      window.settle()
      // The page is above the reader, who still sees the rows they were reading: the page's
      // last row, partly in view above them, only takes its measured height.
      let index = try #require(controller.model.index(of: first))
      #expect(index > 1)
      #expect(abs(controller.tableView.rect(ofRow: index).minY - driver.offset - below) < 8)
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
      #expect(controller.measurements == measured, "\(controller.measurements - measured) more")
      controller.jumpToLatest()
      conversation.stream("streamed", "One line")
      window.settle(0.05)
      conversation.stream("streamed", "One line\n\nand another")
      window.settle(0.05)
      // The streamed row each time, and the footer once its working line goes.
      #expect(controller.measurements - measured <= 4, "\(controller.measurements - measured)")
      #expect(isAtEnd(driver))
    }

    @Test("Over live rows, a link finds its message in the rows the table shows")
    func liveMessageLink() async throws {
      let focus = TranscriptFocus.linking(to: "u11")
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (driver, controller) = try await screen(
        LiveConversation.rowless(hasMore: false), rows: source, focus: focus)
      let window = driver.screen
      defer { window.close() }
      #expect(await window.waitUntil { focus.flashedRowID == "u11" })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(shows("u11", controller))
      #expect(!isAtEnd(driver))
    }

    @Test("Over live rows, a link to an older message reads pages until the table shows it")
    func liveMessageLinkPages() async throws {
      let focus = TranscriptFocus.linking(to: "u1")
      let conversation = LiveConversation.rowless(hasMore: true)
      let source = LiveRowsSource(TranscriptFixture.turns(6, startingAt: 10))
      let (driver, controller) = try await screen(
        conversation, rows: source, actions: pagingActions, focus: focus)
      let window = driver.screen
      defer { window.close() }
      #expect(await window.waitUntil { log.entries == ["older"] })
      try await source.readPage(
        TranscriptFixture.turns(2, startingAt: 4), of: conversation, hasMore: true, on: window)
      #expect(await window.waitUntil { log.entries == ["older", "older"] })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == "u1")

      try await source.readPage(
        TranscriptFixture.turns(2), of: conversation, hasMore: false, on: window)
      #expect(await window.waitUntil { focus.flashedRowID == "u1" })
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(log.entries.count == 2)
      #expect(shows("u1", controller))
    }
  }
#endif
