#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("What surrounds the rows", .serialized)
  @MainActor
  struct TranscriptRowsContentTests {
    let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    func screen(
      _ state: ConversationViewState, actions: ConversationActions = ConversationActions(),
      style: TranscriptStyle = .chat
    ) async throws -> OffscreenWindow<AnyView> {
      let defaults = try #require(UserDefaults(suiteName: "rows-content-\(UUID().uuidString)"))
      let window = transcriptScreen(
        TranscriptView(state: state, actions: actions)
          .transcriptAppearance(
            TranscriptPreferences(defaults: defaults).appearance(style: style)),
        width: 900, height: 600)
      try await letTasksRun(window, milliseconds: 150)
      return window
    }

    func state(
      rows: [Row] = [], status: TurnStatus? = nil,
      _ change: (inout ConversationViewState) -> Void = { _ in }
    ) -> ConversationViewState {
      var header = TranscriptFixture.header
      if let status { header.status = status }
      var state = ConversationViewState(header: header, rows: rows)
      change(&state)
      return state
    }

    // MARK: Empty and loading

    @Test("A new conversation invites a first message; a read-only one says it's empty")
    func emptyStates() async throws {
      let fresh = try await screen(state())
      defer { fresh.close() }
      #expect(try fresh.shows(EmptyTranscriptView.heading))
      #expect(try fresh.shows("Send a message to get started."))

      let readOnly = try await screen(state { $0.header.readOnly = true })
      defer { readOnly.close() }
      #expect(try readOnly.shows("This session has no messages yet."))

      let paged = try await screen(state { $0.hasMoreHistory = true })
      defer { paged.close() }
      #expect(try paged.shows("No messages on this page"))
      #expect(try paged.shows("Load earlier messages to continue."))
    }

    @Test("The first read says it's loading instead of flashing the empty state")
    func hydrating() async throws {
      let window = try await screen(state { $0.isHydrating = true })
      defer { window.close() }
      #expect(try window.shows("Loading conversation\u{2026}"))
      #expect(try !window.shows(EmptyTranscriptView.heading))
    }

    @Test("A side chat starts empty with its own introduction")
    func sideChatIntro() async throws {
      let window = try await screen(
        state { $0.header.settings = SessionSettings(sideChatSourceId: "parent") })
      defer { window.close() }
      #expect(try !window.shows(EmptyTranscriptView.heading))
    }

    // MARK: Banners

    @Test("A continued session links to its successor, and not to itself")
    func superseded() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.openSession = { log.add("open \($0)") }
      let elsewhere = try await screen(
        state(rows: [TranscriptFixture.answer("a")]) {
          $0.sections = [
            EventSection(
              id: "superseded", title: "Continued elsewhere", summary: "Moved on", details: [],
              sessionId: "next")
          ]
        }, actions: actions)
      defer { elsewhere.close() }
      #expect(try elsewhere.shows("Open"))
      let open = try #require(elsewhere.controlFrames.first { $0.width < 200 && $0.minY > 10 })
      try elsewhere.click(CGPoint(x: open.midX, y: open.midY))
      #expect(log.entries == ["open next"])

      let same = try await screen(
        state(rows: [TranscriptFixture.answer("a")]) {
          $0.sections = [
            EventSection(
              id: "superseded", title: "Continued elsewhere", summary: "Moved on", details: [],
              sessionId: TranscriptFixture.header.id)
          ]
        })
      defer { same.close() }
      #expect(try !same.shows("Continued elsewhere"))
    }

    @Test("A failed session offers to resume, unless a row already says so")
    func failureBanner() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.resume = { log.add("resume") }
      let window = try await screen(
        state(rows: [TranscriptFixture.answer("a")]) { $0.header.failureMessage = "Out of disk" },
        actions: actions)
      defer { window.close() }
      #expect(try window.shows("Out of disk"))
      #expect(try window.shows("Resume session"))

      let row = TranscriptFixture.activityRow(
        .error, title: "Failed", summary: "Out of disk", isFailure: true)
      let withRow = try await screen(
        state(rows: [row]) { $0.header.failureMessage = "Out of disk" })
      defer { withRow.close() }
      #expect(try !withRow.shows("Resume session"))
    }

    @Test("A loading problem can be retried or dismissed")
    func errorBanner() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.dismissError = { log.add("dismiss") }
      actions.retry = { log.add("retry") }
      let window = try await screen(
        state(rows: [TranscriptFixture.answer("a")]) { $0.errorMessage = "Network down" },
        actions: actions)
      defer { window.close() }
      #expect(try window.shows("Network down"))
      #expect(try window.shows("Retry"))
      #expect(try window.shows("Dismiss"))
      for frame in window.controlFrames where frame.width < 120 && frame.width > 30 {
        try window.click(CGPoint(x: frame.midX, y: frame.midY))
      }
      #expect(log.entries.contains("dismiss"))
      #expect(log.entries.contains("retry"))
    }

    @Test("A startup section shows its progress line")
    func startupLine() async throws {
      let window = try await screen(
        state {
          $0.sections = [
            EventSection(id: "startup", title: "Starting", summary: "Provisioning", details: [])
          ]
        })
      defer { window.close() }
      #expect(try window.shows("Provisioning"))
    }

    // MARK: The working indicator

    @Test("A running turn shows it's working, until a row streams")
    func workingIndicator() async throws {
      let idle = try await screen(state(rows: [TranscriptFixture.answer("a")]))
      defer { idle.close() }
      #expect(try !idle.shows("Waiting for your response"))

      let blocked = try await screen(
        state(rows: [TranscriptFixture.user("u")], status: .running) {
          $0.decisions = [
            DecisionCard(
              id: "d", carryingSessionId: TranscriptFixture.header.id, title: "Allow it?",
              detail: "A tool", kind: .approval)
          ]
        })
      defer { blocked.close() }
      #expect(try blocked.shows("Waiting for your response to the request below."))
    }

    // MARK: The plan

    func plan() -> EventSection {
      EventSection(
        id: "todos", title: "Plan", summary: "1 of 2",
        details: [
          DetailSection(id: "t1", title: "completed", text: "Read the code"),
          DetailSection(id: "t2", title: "pending", text: "Fix the bug"),
        ])
    }

    @Test("Chat pins the plan above the thread; the CLI leaves it to its rows")
    func planCard() async throws {
      let chat = try await screen(
        state(rows: [TranscriptFixture.user("u")]) { $0.sections = [plan()] })
      defer { chat.close() }
      #expect(try chat.shows("Plan"))
      let cli = try await screen(
        state(rows: [TranscriptFixture.user("u")]) { $0.sections = [plan()] }, style: .cli)
      defer { cli.close() }
      #expect(try !cli.shows("1 of 2"))
    }

    // MARK: Pure rules

    @Test("The viewer's newest message ignores other people's")
    func ownMessage() {
      var theirs = TranscriptFixture.user("theirs")
      theirs.author = "Sam"
      var mine = TranscriptFixture.user("mine")
      mine.author = "Me"
      var conversation = state(rows: [mine, theirs])
      #expect(TranscriptView.ownMessageID(conversation) == nil)
      conversation.viewerName = "Me"
      #expect(TranscriptView.ownMessageID(conversation) == "mine")
      conversation.rows.append(TranscriptFixture.user("no-author"))
      #expect(TranscriptView.ownMessageID(conversation) == "no-author")
    }

    @Test("The last answer skips a streaming or empty one")
    func lastAnswer() {
      var streaming = TranscriptFixture.answer("streaming")
      streaming.isStreaming = true
      let empty = TranscriptFixture.answer("empty", "")
      let settled = TranscriptFixture.answer("settled")
      #expect(TranscriptView.lastAnswerID([settled, empty, streaming]) == "settled")
      #expect(TranscriptView.lastAnswerID([streaming]) == nil)
    }

  }

  // The same surroundings in CLI style.
  extension TranscriptRowsContentTests {

    @Test("CLI style shows the empty and loading states")
    func cliEmptyStates() async throws {
      let fresh = try await screen(state(), style: .cli)
      defer { fresh.close() }
      #expect(try fresh.shows(EmptyTranscriptView.heading))
      let hydrating = try await screen(state { $0.isHydrating = true }, style: .cli)
      defer { hydrating.close() }
      #expect(try hydrating.shows("Loading conversation\u{2026}"))
    }

    @Test("CLI style carries the plan, superseded, failure and error banners in its stream")
    func cliBanners() async throws {
      var actions = ConversationActions()
      let log = self.log
      actions.resume = { log.add("resume") }
      actions.openSession = { log.add("open \($0)") }
      let window = try await screen(
        state(rows: [TranscriptFixture.answer("a")]) {
          $0.sections = [
            plan(),
            EventSection(
              id: "superseded", title: "Continued elsewhere", summary: "Moved on", details: [],
              sessionId: "next"),
          ]
          $0.header.failureMessage = "Out of disk"
          $0.errorMessage = "Network down"
        }, actions: actions, style: .cli)
      defer { window.close() }
      for text in ["Plan", "Continued elsewhere", "Out of disk", "Network down"] {
        #expect(try window.shows(text), "\(text)")
      }
      let row = TranscriptFixture.activityRow(
        .error, title: "Failed", summary: "Out of disk", isFailure: true)
      let withRow = try await screen(
        state(rows: [row]) { $0.header.failureMessage = "Out of disk" }, style: .cli)
      defer { withRow.close() }
      #expect(try !withRow.shows("Resume session"))
      let toItself = try await screen(
        state(rows: [TranscriptFixture.answer("a")]) {
          $0.sections = [
            EventSection(
              id: "superseded", title: "Continued elsewhere", summary: "Moved on", details: [],
              sessionId: TranscriptFixture.header.id)
          ]
        }, style: .cli)
      defer { toItself.close() }
      #expect(try !toItself.shows("Continued elsewhere"))
    }

    @Test("CLI style shows a running turn's working line until a row streams")
    func cliWorkingLine() async throws {
      let blocked = try await screen(
        state(rows: [TranscriptFixture.user("u")], status: .running) {
          $0.decisions = [
            DecisionCard(
              id: "d", carryingSessionId: TranscriptFixture.header.id, title: "Allow it?",
              detail: "A tool", kind: .approval)
          ]
        }, style: .cli)
      defer { blocked.close() }
      #expect(try blocked.shows("Allow it?"))

      var streaming = TranscriptFixture.answer("a", "Typing")
      streaming.isStreaming = true
      let live = try await screen(state(rows: [streaming], status: .running), style: .cli)
      defer { live.close() }
      #expect(try live.shows("Typing"))
    }

    @Test("A settled turn ends with how long it worked, and a live one doesn't")
    func cliFooter() throws {
      let finished = try #require(ISO8601DateFormatter().date(from: "2026-03-01T09:47:00Z"))
      let answer = TranscriptFixture.answer("a", responseID: "r")
      let segments = TurnLayout.segments(
        TranscriptLayout.items(for: [TranscriptFixture.user("u"), answer]), isRunning: false)
      let settled = CLILayout.blocks(
        segments, durations: ["r": 12], timestamps: ["a": finished], isRunning: false,
        now: finished)
      let footer = try #require(settled.last)
      guard case .footer(_, let text) = footer else {
        Issue.record("Expected a footer, got \(footer)")
        return
      }
      #expect(text.hasPrefix("Worked for 12s \u{2022} "))
      #expect(footer.id.hasPrefix("footer:"))

      let live = CLILayout.blocks(
        segments, durations: ["r": 12], timestamps: [:], isRunning: true, now: finished)
      #expect(!live.contains { $0.id.hasPrefix("footer:") })
      // A turn closed by the next user message settles even while running.
      let closed = CLILayout.blocks(
        segments, durations: ["r": 12], timestamps: [:], isRunning: true, closesLastTurn: true,
        now: finished)
      #expect(closed.contains { $0.id.hasPrefix("footer:") })
      // Nothing to report: no footer.
      let bare = CLILayout.blocks(segments, durations: [:], timestamps: [:], isRunning: false)
      #expect(!bare.contains { $0.id.hasPrefix("footer:") })
    }

    @Test("CLI style opens at the newest row")
    func cliOpensAtBottom() async throws {
      let window = try await screen(state(rows: TranscriptFixture.turns(8)), style: .cli)
      defer { window.close() }
      let viewport = TranscriptScrollDriver(screen: window)
      #expect(viewport.distanceToEnd() < 80)
      #expect(try window.shows("Question 7"))
    }
  }
#endif
