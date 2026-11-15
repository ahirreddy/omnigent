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

  /// Rows whose changes the list is not told about, as when the pacer holds a burst for a tick.
  @MainActor
  private final class HeldRows {
    private var rows: [Row]
    private var revision: UInt64 = 1

    init(_ rows: [Row]) {
      self.rows = rows
    }

    var reader: LiveTranscriptRows {
      LiveTranscriptRows { (rows: self.rows, revision: self.revision) }
    }

    /// Puts a page above the rows.
    func prepend(_ page: [Row]) {
      rows.insert(contentsOf: page, at: 0)
      revision += 1
    }

  }

  /// The transcript reading its rows apart from the conversation's paging state, as the app does.
  private struct HeldRowsTranscript: View {
    let conversation: LiveConversation
    let rows: LiveTranscriptRows
    let actions: ConversationActions

    var body: some View {
      TranscriptView(
        state: conversation.state, liveRows: rows, actions: actions, scrollToLatestRequest: 0)
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
      #expect(try await waitUntil(window) { try window.shows("From the live rows") })
      #expect(try !window.shows("From the state"))
    }

    @Test("Jump to top keeps paging when a page's rows reach the list after its read ends")
    func jumpToTopWithLateRows() async throws {
      let rows = HeldRows(TranscriptFixture.turns(6, startingAt: 10))
      var state = ConversationViewState(header: TranscriptFixture.header, rows: [])
      state.hasMoreHistory = true
      let conversation = LiveConversation(state)
      var actions = ConversationActions()
      actions.loadOlder = { [log] in log.add("older") }
      let window = transcriptScreen(
        HeldRowsTranscript(conversation: conversation, rows: rows.reader, actions: actions),
        width: 900, height: 500)
      defer { window.close() }
      try await letOpeningEnd(window)
      let viewport = TranscriptScrollDriver(screen: window)
      viewport.move(to: viewport.offset - 50)
      log.clear()
      try window.hover(CGPoint(x: 450, y: 40))
      try window.click(CGPoint(x: 450, y: 22))
      #expect(log.entries == ["older"])

      // The read ends while the list still shows the rows from before the page.
      conversation.state.isLoadingHistory = true
      try await letTasksRun(window)
      rows.prepend(TranscriptFixture.turns(1, startingAt: 5))
      conversation.state.isLoadingHistory = false
      try await letTasksRun(window)
      #expect(log.entries == ["older", "older"])

      // The last page, read between two renders, so the transcript never sees it loading:
      // the list takes all that was read, and the jump ends at its top.
      rows.prepend(TranscriptFixture.turns(1, startingAt: 2))
      conversation.state.hasMoreHistory = false
      conversation.state.historyReads += 1
      #expect(try await waitUntil(window) { viewport.offset < 30 })
      #expect(log.entries.count == 2)
      #expect(try window.shows("Question 2"))
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

    /// How far a working turn's last row rests above the dock, in a pane `width` wide.
    private func gapUnderLastRow(width: CGFloat, style: TranscriptStyle) async throws -> CGFloat {
      var header = TranscriptFixture.header
      header.status = .running
      let conversation = LiveConversation(
        ConversationViewState(header: header, rows: TranscriptFixture.turns(3)))
      let height: CGFloat = 600
      let dock: CGFloat = 120
      let window = transcriptScreen(
        DockedTranscriptHost(
          conversation: conversation, pane: TranscriptPane(width: width, dock: dock)
        )
        .transcriptAppearance(TranscriptAppearance(style: style)),
        width: width, height: height)
      defer { window.close() }
      try await letOpeningEnd(window)
      conversation.scrollRequest += 1
      try await letTasksRun(window, milliseconds: 400)
      let working = try window.withAccessibilityTree {
        try window.accessibilityFrame("transcript-working")
      }
      // A chat row is at least a control high, with its line centered in it.
      let rowHeight = style == .cli ? working.height : max(working.height, Theme.Control.target)
      return (height - dock) - (working.midY + rowHeight / 2)
    }

    @Test(
      "A working turn's last row rests one row gap above the dock, in a narrow or wide pane",
      arguments: [(760, .chat), (1_200, .chat), (760, .cli), (1_200, .cli)]
        as [(CGFloat, TranscriptStyle)])
    func lastRowToComposer(width: CGFloat, style: TranscriptStyle) async throws {
      let gap = try await gapUnderLastRow(width: width, style: style)
      // The stack's gap between two rows, and the point-high row the transcript scrolls to.
      let rowGap = style == .cli ? CLIMetrics.blockGap : Theme.Spacing.row
      #expect(abs(gap - (rowGap + 1)) <= 0.5, "\(gap) points under the last row")
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
      #expect(try await waitUntil(window) { try window.shows("the terminal surface") })
      #expect(try window.shows("Allow it?"))
      #expect(!window.allViews.contains { $0 is NSTextView })
    }

    @Test("A sign-in code fetched from a transcript row can be copied")
    func signInCodeCopies() async throws {
      SystemSideEffects.reset()
      var actions = ConversationActions()
      actions.openSignIn = { .opened(code: "ABCD-1234") }
      let failure = Activity(
        kind: .error, title: "Turn failed", summary: "Sign in again",
        details: [
          DetailSection(id: "code", title: "Code", text: "databricks_sign_in_pending")
        ],
        isFailure: true)
      let state = ConversationViewState(
        header: TranscriptFixture.header,
        rows: [Row(id: "failure", role: .tool, activity: failure)])
      let window = transcriptScreen(
        TranscriptView(state: state, actions: actions, scrollToLatestRequest: 0), width: 900)
      defer { window.close() }
      let isLink = { (frame: CGRect) in frame.width > 120 && frame.width < 240 }
      #expect(try await waitUntil(window) { window.controlFrames.contains(where: isLink) })
      let link = try #require(window.controlFrames.first(where: isLink))
      try window.click(CGPoint(x: link.midX, y: link.midY))
      #expect(try await waitUntil(window) { try window.shows("Copy Code ABCD-1234") })
      let copy = try #require(
        window.controlFrames.first { $0.minX >= link.maxX && abs($0.midY - link.midY) < 4 })
      try window.click(CGPoint(x: copy.midX, y: copy.midY))
      #expect(copiedText() == "ABCD-1234")
    }
  }
#endif
