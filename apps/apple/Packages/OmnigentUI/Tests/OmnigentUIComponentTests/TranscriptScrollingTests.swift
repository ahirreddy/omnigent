#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript scrolling", .serialized)
  @MainActor
  struct TranscriptScrollingTests {
    private static let width: CGFloat = 900
    private static let height: CGFloat = 500
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func screen(
      _ conversation: LiveConversation, actions: ConversationActions = ConversationActions()
    ) async throws -> (OffscreenWindow<AnyView>, TranscriptScrollDriver) {
      let window = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: actions), width: Self.width,
        height: Self.height)
      try await letTasksRun(window, milliseconds: 200)
      return (window, TranscriptScrollDriver(screen: window))
    }

    private func longSession(_ turns: Int = 8) -> LiveConversation {
      LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(turns)))
    }

    private var jumpPill: CGPoint { CGPoint(x: Self.width / 2, y: Self.height - 34) }

    /// The pill shows once the transcript has framed the latest question. The test stops without
    /// it: what follows would only report a click on nothing.
    private func clickJumpPill(on window: OffscreenWindow<AnyView>) async throws {
      let viewport = TranscriptScrollDriver(screen: window)
      try #require(
        try await waitUntil(window) { try window.shows("Jump to latest") },
        "No pill, at offset \(viewport.offset) of \(viewport.maximumOffset)")
      try window.click(jumpPill)
    }

    /// Previous is above Next at the transcript's bottom-trailing corner.
    private func navigatorButton(
      _ direction: TranscriptNavigation.Direction, on window: OffscreenWindow<AnyView>
    ) throws -> CGPoint {
      let buttons = navigatorButtons(on: window, width: Self.width)
      let button = try #require(direction == .previous ? buttons.first : buttons.last)
      #expect(buttons.count == 2)
      return CGPoint(x: button.midX, y: button.midY)
    }

    @Test("Opening a session frames its latest question, so a long answer reads from its start")
    func opensAtLatestQuestion() async throws {
      let (window, viewport) = try await screen(longSession())
      defer { window.close() }
      #expect(viewport.maximumOffset > 0)
      #expect(try window.shows("Question 7"))
      #expect(try window.shows("Line 0 of answer 7"))
      #expect(try await waitUntil(window) { try window.shows("Jump to latest") })
    }

    @Test("A busy main thread can't lose the pill, or leave output moving a reader framed earlier")
    func framingOutlastsLateLayout() async throws {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(8))
      state.viewerName = "Me"
      let conversation = LiveConversation(state)
      let window = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions()),
        width: Self.width, height: Self.height)
      defer { window.close() }
      // The view's task resumes once this test suspends, with SwiftUI's update held back.
      let busyLoop = BusyMainRunLoop()
      busyLoop.start()
      try await Task.sleep(for: .milliseconds(200))
      busyLoop.stop()
      try await letTasksRun(window, milliseconds: 100)
      #expect(try window.shows("Line 0 of answer 7"))
      #expect(try await waitUntil(window) { try window.shows("Jump to latest") })

      let viewport = TranscriptScrollDriver(screen: window)
      let reading = viewport.offset
      var other = TranscriptFixture.user("theirs", "Someone else asks")
      other.author = "Sam"
      conversation.append(other)
      try await letTasksRun(window, milliseconds: 300)
      #expect(abs(viewport.offset - reading) < 2)
      #expect(try window.shows("New output"))
    }

    @Test("A short conversation just keeps following")
    func shortConversationFollows() async throws {
      let (window, _) = try await screen(
        LiveConversation(
          ConversationViewState(
            header: TranscriptFixture.header,
            rows: [TranscriptFixture.user("u"), TranscriptFixture.answer("a")])))
      defer { window.close() }
      #expect(try !window.shows("Jump to latest"))
      #expect(try window.shows("An answer"))
    }

    @Test("At the bottom, new output keeps the newest row in view")
    func followsNewOutput() async throws {
      let conversation = longSession()
      let (window, viewport) = try await screen(conversation)
      defer { window.close() }
      try await clickJumpPill(on: window)
      try await letTasksRun(window, milliseconds: 400)
      #expect(try !window.shows("Jump to latest"))
      conversation.append(TranscriptFixture.answer("more", "Fresh output at the end"))
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.distanceToEnd() < 80)
      #expect(try window.shows("Fresh output at the end"))
    }

    @Test("Scrolling up keeps the reader in place while output arrives, and the pill leads back")
    func readerKeepsPlace() async throws {
      let conversation = longSession()
      let (window, viewport) = try await screen(conversation)
      defer { window.close() }
      try await clickJumpPill(on: window)
      try await letTasksRun(window, milliseconds: 400)
      try window.click(try navigatorButton(.previous, on: window))
      try await letTasksRun(window, milliseconds: 300)
      let reading = viewport.offset
      #expect(try window.shows("Jump to latest"))

      conversation.append(TranscriptFixture.answer("more", "Fresh output at the end"))
      try await letTasksRun(window, milliseconds: 300)
      #expect(abs(viewport.offset - reading) < 2)
      #expect(try window.shows("New output"))

      try window.click(jumpPill)
      try await letTasksRun(window, milliseconds: 400)
      #expect(viewport.distanceToEnd() < 80)
      #expect(try !window.shows("New output"))
    }

    @Test("A menu command goes to the newest row from anywhere")
    func scrollToLatestRequest() async throws {
      let conversation = longSession()
      let (window, viewport) = try await screen(conversation)
      defer { window.close() }
      viewport.move(to: 0)
      conversation.scrollRequest += 1
      try await letTasksRun(window, milliseconds: 400)
      #expect(viewport.distanceToEnd() < 80)
    }

    @Test("Sending a message takes the reader to it, wherever they were reading")
    func ownMessageJumps() async throws {
      let conversation = longSession()
      let (window, viewport) = try await screen(conversation)
      defer { window.close() }
      viewport.move(to: 0)
      conversation.append(TranscriptFixture.user("mine", "My new question"))
      try await letTasksRun(window, milliseconds: 400)
      #expect(viewport.distanceToEnd() < 80)
      #expect(try window.shows("My new question"))
    }

    @Test("Someone else's message doesn't move the reader")
    func othersMessageStays() async throws {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(8))
      state.viewerName = "Me"
      let conversation = LiveConversation(state)
      let (window, viewport) = try await screen(conversation)
      defer { window.close() }
      viewport.move(to: 0)
      var other = TranscriptFixture.user("theirs", "Someone else asks")
      other.author = "Sam"
      conversation.append(other)
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.distanceToEnd() > 80)
    }

    @Test("Resizing the window keeps a reader at the bottom there")
    func resizeKeepsBottom() async throws {
      let conversation = longSession()
      let (window, viewport) = try await screen(conversation)
      defer { window.close() }
      try await clickJumpPill(on: window)
      try await letTasksRun(window, milliseconds: 400)
      window.host.setFrameSize(NSSize(width: 600, height: Self.height))
      #expect(try await waitUntil(window) { viewport.distanceToEnd() < 80 })
    }

    // MARK: Message navigation

    @Test("Previous and next need a second question to move between")
    func navigatorShowsWithTwoQuestions() async throws {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(1)))
      let (window, _) = try await screen(conversation)
      defer { window.close() }
      #expect(!window.controlFrames.contains { $0.maxX > Self.width - 40 && $0.minY > 300 })
      conversation.append(contentsOf: TranscriptFixture.turns(1, startingAt: 1))
      try await letTasksRun(window)
      #expect(try navigatorButton(.next, on: window).y > navigatorButton(.previous, on: window).y)
    }

    @Test("Previous moves up a question at a time and Next comes back down")
    func navigatorMoves() async throws {
      let (window, viewport) = try await screen(longSession())
      defer { window.close() }
      let start = viewport.offset
      try window.click(try navigatorButton(.previous, on: window))
      try await letTasksRun(window, milliseconds: 300)
      let onePrevious = viewport.offset
      #expect(onePrevious < start)
      try window.click(try navigatorButton(.previous, on: window))
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.offset < onePrevious)
      try window.click(try navigatorButton(.next, on: window))
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.offset > 0)
      #expect(viewport.offset <= start)
      #expect(try window.shows("Jump to latest"))
    }

    @Test("The keyboard shortcuts move between questions too")
    func navigatorShortcuts() async throws {
      let (window, viewport) = try await screen(longSession())
      defer { window.close() }
      let start = viewport.offset
      try window.press(
        keyCode: 126, characters: "\u{F700}", modifiers: [.command, .option, .numericPad])
      try await letTasksRun(window, milliseconds: 300)
      #expect(viewport.offset < start)
    }

    @Test("With no question below, Next goes to the newest row")
    func nextAtEnd() async throws {
      let (window, viewport) = try await screen(longSession())
      defer { window.close() }
      try window.click(try navigatorButton(.next, on: window))
      try await letTasksRun(window, milliseconds: 400)
      #expect(viewport.distanceToEnd() < 80)
      #expect(try !window.shows("Jump to latest"))
    }

    @Test("With no question above, Previous loads older history")
    func previousAtStartLoadsOlder() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.loadOlder = { log.add("older") }
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(2))
      state.hasMoreHistory = true
      let (window, viewport) = try await screen(LiveConversation(state), actions: actions)
      defer { window.close() }
      viewport.move(to: 0)
      try window.click(try navigatorButton(.previous, on: window))
      try await letTasksRun(window)
      #expect(log.entries.first == "older")
    }
  }
#endif
