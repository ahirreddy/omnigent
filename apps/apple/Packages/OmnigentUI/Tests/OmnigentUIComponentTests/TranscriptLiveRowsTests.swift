#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  private final class RowsSource {
    var rows: [Row]
    var revision: UInt64 = 1

    init(_ rows: [Row]) {
      self.rows = rows
    }

    var reader: LiveTranscriptRows {
      LiveTranscriptRows { (rows: self.rows, revision: self.revision) }
    }
  }

  @Suite("Live rows and resizing", .serialized)
  @MainActor
  struct TranscriptLiveRowsTests {
    private let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    @Test("A transcript over live rows shows them, not the state's")
    func liveRows() async throws {
      let source = RowsSource([TranscriptFixture.answer("live", "From the live rows")])
      let state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("old", "From the state")])
      let window = transcriptScreen(
        LiveTranscript(
          state: state, liveRows: source.reader, actions: ConversationActions(),
          scrollToLatestRequest: 0))
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      #expect(try window.shows("From the live rows"))
      #expect(try !window.shows("From the state"))
    }

    @Test("Resizing while reading earlier keeps the reader on what they were reading")
    func resizeWhileReading() async throws {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(8)))
      let window = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions()), width: 900,
        height: 500)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      driver.move(to: driver.offset / 2)
      try await letTasksRun(window)
      window.host.setFrameSize(NSSize(width: 700, height: 500))
      try await letTasksRun(window, milliseconds: 300)
      #expect(driver.offset > 0)
      #expect(driver.distanceToEnd() > 80)
      // A second resize finds the row's height at the width it's already been measured at.
      window.host.setFrameSize(NSSize(width: 900, height: 500))
      try await letTasksRun(window, milliseconds: 300)
      #expect(driver.distanceToEnd() > 80)
    }

    @Test("The rail's preview goes when the pointer leaves the ticks or the rail")
    func railHoverEnds() async throws {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(6, startingAt: 10)))
      let window = transcriptScreen(
        LiveTranscriptHost(conversation: conversation, actions: ConversationActions()), width: 900,
        height: 500)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let railHeight = CGFloat(6) * TurnRail.pitch + 2 * TurnRail.fade
      let top = (500 - railHeight) / 2
      // The whole reply as one string: the transcript draws its paragraphs apart.
      let firstTick = CGPoint(x: 16, y: top + TurnRail.fade + 2.5 * TurnRail.pitch)
      let preview = "Line 0 of answer 12\n\nLine 1 of answer 12"
      #expect(try !window.shows(preview))

      try window.hover(firstTick)
      try await letTasksRun(window)
      #expect(try window.shows(preview))
      // The fade above the ticks has no tick under it.
      try window.hover(CGPoint(x: 16, y: top + 4))
      try await letTasksRun(window)
      #expect(try !window.shows(preview))

      try window.hover(firstTick)
      try await letTasksRun(window)
      #expect(try window.shows(preview))
      try window.endHover()
      try await letTasksRun(window)
      #expect(try !window.shows(preview))
    }

    @Test("The room the navigator keeps under the last row depends on whether it fits beside")
    func navigatorClearance() {
      let beside = TranscriptNavigator.bottomClearance(layout: .card, width: 2000, column: 700)
      let over = TranscriptNavigator.bottomClearance(layout: .card, width: 700, column: 700)
      #expect(beside == 0)
      #expect(over > 0)
      #expect(TranscriptNavigator.bottomClearance(layout: .touch, width: 700, column: 700) == 0)
    }

    // MARK: The composer's remaining rows

    @Test("A dropped connection shows under the status line and can reconnect")
    func connectionNotice() throws {
      var state = ComposerViewState()
      state.connection = ComposerConnectionNotice(message: "Connection lost", isFailure: true)
      var extras = ComposerExtraActions()
      let log = self.log
      extras.reconnect = { log.add("reconnect") }
      let screen = try cliComposerScreen(state, actions: ComposerActions(send: {}, extras: extras))
      defer { screen.close() }
      #expect(try screen.shows("Connection lost"))
      let button = try #require(screen.controlFrames.last)
      try screen.click(CGPoint(x: button.midX, y: button.midY))
      #expect(log.entries == ["reconnect"])
    }

    @Test("The up arrow recalls the last prompt into an empty field")
    func recallsPrompt() async throws {
      var extras = ComposerExtraActions()
      extras.recallPrevious = { "Asked before" }
      let screen = try cliComposerScreen(
        ComposerViewState(), actions: ComposerActions(send: {}, extras: extras))
      defer { screen.close() }
      try await letTasksRun(screen, milliseconds: 200)
      try screen.press(keyCode: 126, characters: "\u{F700}")
      try await letTasksRun(screen)
      let editor = try #require(screen.allViews.compactMap { $0 as? NSTextView }.first)
      #expect(editor.string == "Asked before")
    }

    @Test("Background tasks show among the status line's indicators")
    func indicators() throws {
      var tray = ComposerTray()
      tray.indicators = ComposerTaskIndicators(backgroundTasks: 2)
      let screen = try cliComposerScreen(
        ComposerViewState(tray: tray), actions: ComposerActions(send: {}))
      defer { screen.close() }
      #expect(try screen.shows("2"))
    }

    // MARK: The screen's remaining paths

    @Test("In Terminal, a pending request still docks and the composer stays away")
    func terminalWithDecision() async throws {
      var state = ConversationViewState(header: TranscriptFixture.header, terminal: .ready)
      state.decisions = [
        DecisionCard(
          id: "d", carryingSessionId: TranscriptFixture.header.id, title: "Allow it?",
          detail: "A tool", kind: .approval)
      ]
      let window = transcriptScreen(
        ConversationScreen(
          state: state, composer: ComposerViewState(), draft: ComposerDraft(.constant("")),
          showsInspector: .constant(false), mode: .constant(.terminal),
          actions: ConversationActions(), composerActions: ComposerActions(send: {})
        ) {
          Text("the terminal surface")
        }, width: 900, height: 600)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 150)
      #expect(try window.shows("the terminal surface"))
      #expect(try window.shows("Allow it?"))
      #expect(!window.allViews.contains { $0 is NSTextView })
    }
  }
#endif
