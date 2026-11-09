#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript history and links", .serialized)
  @MainActor
  struct TranscriptHistoryTests {
    static let width: CGFloat = 900
    static let height: CGFloat = 500
    let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    var pagingActions: ConversationActions {
      var actions = ConversationActions()
      let log = self.log
      actions.loadOlder = { log.add("older") }
      return actions
    }

    func screen(
      _ conversation: LiveConversation, actions: ConversationActions = ConversationActions(),
      focus: TranscriptFocus? = nil
    ) async throws -> (OffscreenWindow<AnyView>, TranscriptScrollDriver) {
      let window = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: actions)
          .environment(\.transcriptFocus, focus),
        width: Self.width, height: Self.height)
      try await letTasksRun(window, milliseconds: 200)
      return (window, TranscriptScrollDriver(screen: window))
    }

    func session(turns: Int = 6, hasMore: Bool = false) -> LiveConversation {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(turns, startingAt: 10))
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    // MARK: Older history

    @Test("The top of the history offers more, and says when it's reading")
    func historyHeader() async throws {
      let conversation = session(hasMore: true)
      let (window, viewport) = try await screen(conversation, actions: pagingActions)
      defer { window.close() }
      viewport.move(to: 0)
      #expect(try window.shows("Load earlier messages"))
      let button = try loadEarlierButton(on: window)
      log.clear()
      try window.click(CGPoint(x: button.midX, y: button.midY))
      #expect(log.entries == ["older"])

      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      #expect(try window.shows("Loading earlier messages\u{2026}"))
      #expect(!window.controlFrames.contains(button))

      // A lazy stack's tree keeps text it removed, so ask for the control itself.
      conversation.state.isLoadingHistory = false
      conversation.state.hasMoreHistory = false
      try await letTasksRun(window)
      #expect(!window.controlFrames.contains(button))
    }

    /// The history header's button: above the first row and wider than the round Jump to top.
    private func loadEarlierButton(on window: OffscreenWindow<AnyView>) throws -> CGRect {
      try #require(window.controlFrames.first { $0.width > 28 && $0.width < 400 && $0.minY < 100 })
    }

    @Test("Without a way to page there's no offer")
    func noPagingNoOffer() async throws {
      let (window, viewport) = try await screen(session(hasMore: true))
      defer { window.close() }
      viewport.move(to: 0)
      #expect(try !window.shows("Load earlier messages"))
    }

    @Test("Older rows landing above leave the reader where they were")
    func pageHoldsPosition() async throws {
      let conversation = session(hasMore: true)
      let (window, viewport) = try await screen(conversation, actions: pagingActions)
      defer { window.close() }
      viewport.move(to: 0)
      #expect(log.entries.contains("older"))
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(3), at: 0)
      conversation.state.revision += 1
      conversation.state.isLoadingHistory = false
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.offset > 200)
      #expect(try window.shows("Question 10"))
    }

    @Test("Reading near the top pages in more once the reader has left the bottom")
    func nearTopPages() async throws {
      let conversation = session(hasMore: true)
      let (window, viewport) = try await screen(conversation, actions: pagingActions)
      defer { window.close() }
      // Opening frames the latest question, which stops following.
      viewport.move(to: 0)
      try await letTasksRun(window)
      #expect(log.entries.contains("older"))
    }

    // MARK: Jump to top

    @Test("Pointing at the top shows Jump to top, which goes there")
    func jumpToTop() async throws {
      let (window, viewport) = try await screen(session())
      defer { window.close() }
      #expect(viewport.offset > 100)
      let top = CGPoint(x: Self.width / 2, y: 22)
      try window.click(top)
      #expect(viewport.offset > 100)
      viewport.move(to: viewport.offset - 50)
      try window.hover(CGPoint(x: Self.width / 2, y: 40))
      try window.click(top)
      try await letTasksRun(window, milliseconds: 400)
      #expect(viewport.offset < 30)
    }

    @Test("Jump to top keeps paging in history until there's none, then goes there")
    func jumpToTopPages() async throws {
      let conversation = session(hasMore: true)
      let (window, viewport) = try await screen(conversation, actions: pagingActions)
      defer { window.close() }
      viewport.move(to: viewport.offset - 50)
      log.clear()
      try window.hover(CGPoint(x: Self.width / 2, y: 40))
      try window.click(CGPoint(x: Self.width / 2, y: 22))
      #expect(log.entries == ["older"])

      // A page with rows lands, and more remains: it asks for the next.
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(1), at: 0)
      conversation.state.revision += 1
      conversation.state.isLoadingHistory = false
      try await letTasksRun(window)
      #expect(log.entries == ["older", "older"])

      // The last page lands: it goes to the top.
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(1, startingAt: 1), at: 0)
      conversation.state.revision += 1
      conversation.state.hasMoreHistory = false
      conversation.state.isLoadingHistory = false
      try await letTasksRun(window, milliseconds: 300)
      #expect(log.entries.count == 2)
      #expect(viewport.offset < 30)
    }

    @Test("A page that brings nothing stops Jump to top where it is")
    func jumpToTopEmptyPage() async throws {
      let conversation = session(hasMore: true)
      let (window, viewport) = try await screen(conversation, actions: pagingActions)
      defer { window.close() }
      viewport.move(to: viewport.offset - 50)
      log.clear()
      try window.hover(CGPoint(x: Self.width / 2, y: 40))
      try window.click(CGPoint(x: Self.width / 2, y: 22))
      #expect(log.entries == ["older"])
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      conversation.state.isLoadingHistory = false
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.offset < 30)
      // Arriving at the top may ask once more, as any reader reaching the top does.
      #expect(log.entries.count <= 2)
    }

    @Test("What counts as being at the top, and what a scroll does to the pill")
    func scrollTopRules() {
      #expect(ScrollTopReveal.isAtTop(1, wasAtTop: false))
      #expect(!ScrollTopReveal.isAtTop(5, wasAtTop: false))
      #expect(ScrollTopReveal.isAtTop(5, wasAtTop: true))
      #expect(ScrollTopReveal.change(delta: -5, isAtTop: false, isRevealed: false) == .reveal)
      #expect(ScrollTopReveal.change(delta: -5, isAtTop: true, isRevealed: false) == .unchanged)
      #expect(ScrollTopReveal.change(delta: 5, isAtTop: false, isRevealed: true) == .hide)
      #expect(ScrollTopReveal.change(delta: 5, isAtTop: false, isRevealed: false) == .unchanged)
    }

  }

  // Message links and the turn rail.
  extension TranscriptHistoryTests {

    @Test("A message link scrolls to the message, flashes it, and only happens once")
    func messageLink() async throws {
      let focus = TranscriptFocus()
      focus.focus("u11", in: TranscriptFixture.header.id)
      let (window, viewport) = try await screen(session(), focus: focus)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 300)
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(focus.flashedRowID == "u11")
      #expect(viewport.offset > 0)
      #expect(try window.shows("Question 11"))
    }

    @Test("A link to an older message pages until the message is there")
    func messageLinkPages() async throws {
      let focus = TranscriptFocus()
      focus.focus("u1", in: TranscriptFixture.header.id)
      let conversation = session(hasMore: true)
      let (window, _) = try await screen(conversation, actions: pagingActions, focus: focus)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 300)
      #expect(log.entries.first == "older")
      #expect(focus.messageID(in: TranscriptFixture.header.id) == "u1")

      conversation.state.rows.insert(contentsOf: TranscriptFixture.turns(2), at: 0)
      conversation.state.revision += 1
      conversation.state.hasMoreHistory = false
      try await letTasksRun(window, milliseconds: 300)
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(focus.flashedRowID == "u1")
    }

    @Test("A link to a message that doesn't exist gives up and stays at the latest")
    func messageLinkMissing() async throws {
      let focus = TranscriptFocus()
      focus.focus("gone", in: TranscriptFixture.header.id)
      let (window, _) = try await screen(session(), focus: focus)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 300)
      #expect(focus.messageID(in: TranscriptFixture.header.id) == nil)
      #expect(focus.flashedRowID == nil)
    }

    @Test("A link waits while the conversation is still empty")
    func messageLinkWaitsForRows() async throws {
      let focus = TranscriptFocus()
      focus.focus("u10", in: TranscriptFixture.header.id)
      let conversation = LiveConversation(ConversationViewState(header: TranscriptFixture.header))
      let (window, _) = try await screen(conversation, focus: focus)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 300)
      #expect(focus.messageID(in: TranscriptFixture.header.id) == "u10")
      conversation.append(contentsOf: TranscriptFixture.turns(1, startingAt: 10))
      try await letTasksRun(window, milliseconds: 200)
      #expect(focus.flashedRowID == "u10")
    }

    // MARK: The turn rail

    private func tick(_ index: Int, of count: Int) -> CGPoint {
      let railHeight = min(
        TurnRail.maxHeight, CGFloat(count) * TurnRail.pitch + 2 * TurnRail.fade)
      let top = (Self.height - railHeight) / 2
      let tickY = top + TurnRail.fade + (CGFloat(index) + 0.5) * TurnRail.pitch
      return CGPoint(x: 16, y: tickY)
    }

    @Test("Clicking a tick on the rail scrolls to that turn and flashes it")
    func railJump() async throws {
      let focus = TranscriptFocus()
      let (window, viewport) = try await screen(session(), focus: focus)
      defer { window.close() }
      let start = viewport.offset
      try window.click(tick(1, of: 6))
      try await letTasksRun(window, milliseconds: 300)
      #expect(focus.flashedRowID == "u11")
      #expect(viewport.offset < start)
      #expect(try window.shows("Jump to latest"))
    }

    @Test("Pointing at a tick previews the turn and the start of its reply")
    func railPreview() async throws {
      let (window, _) = try await screen(session())
      defer { window.close() }
      // The whole reply as one string: the transcript draws its paragraphs apart.
      let reply = "Line 0 of answer 12\n\nLine 1 of answer 12"
      #expect(try !window.shows(reply))
      try window.hover(tick(2, of: 6))
      try await letTasksRun(window)
      #expect(try window.shows(reply))
      // Past the ticks there's nothing to preview.
      try window.hover(CGPoint(x: 16, y: Self.height / 2 + 200))
      try await letTasksRun(window)
      #expect(try !window.shows("(no text)"))
      try window.endHover()
    }

    @Test("Finding the active turn and a turn's reply")
    func railRules() {
      let order = ["a", "u1", "b", "c", "u2", "d"]
      let turns: Set<String> = ["u1", "u2"]
      #expect(TurnRailModel.activeTurn(order: order, turns: turns, visible: []) == nil)
      #expect(TurnRailModel.activeTurn(order: order, turns: turns, visible: ["a"]) == "u1")
      #expect(TurnRailModel.activeTurn(order: order, turns: turns, visible: ["b", "c"]) == "u1")
      #expect(TurnRailModel.activeTurn(order: order, turns: turns, visible: ["d"]) == "u2")
    }

    @Test("A phone-width transcript leaves the rail out")
    func railCompact() async throws {
      let window = transcriptScreen(
        LiveTranscriptHost(conversation: session(), actions: ConversationActions()),
        width: Self.width, height: Self.height, layout: .compact)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      #expect(window.allViews.compactMap { $0 as? NSScrollView }.count == 1)
    }
  }
#endif
