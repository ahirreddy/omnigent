#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The rows the web draws for what is not the person's own words: runtime notices, sub-agent
  /// and task markers, a thought's preview and a message another session sent.
  @Suite("Transcript markers and notices", .serialized)
  @MainActor
  struct TranscriptMarkerRowTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func body(_ text: String) -> [DetailSection] {
      [DetailSection(id: "body", title: "Details", text: text)]
    }

    @Test("A notice reads 'System: …' and opens to its body; one without a body does not open")
    func notice() throws {
      let row = Fixture.activityRow(
        .systemNotice, title: "Timer t1 fired", summary: "note: check the build",
        status: "timer_fired", details: body("note: check the build"))
      let screen = transcriptScreen(ActivityRowView(row: row))
      defer { screen.close() }
      #expect(try screen.shows("System: Timer t1 fired"))
      #expect(try !screen.shows("note: check the build"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("note: check the build"))

      let idle = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .systemNotice, title: "Terminal shell:s1 idle", status: "terminal_idle")))
      defer { idle.close() }
      #expect(try idle.shows("System: Terminal shell:s1 idle"))
      #expect(idle.controlFrames.isEmpty)
    }

    @Test("A sub-agent marker names its phase and title, and the title opens its session")
    func subagentMarker() throws {
      let log = HostLog()
      var actions = ConversationActions()
      actions.openChild = { log.add("child \($0)") }
      let row = Fixture.activityRow(
        .subagentMarker, title: "Completed", summary: "Explore auth", status: "returned",
        details: [DetailSection(id: "session", title: "Session", text: "child-1", isCode: true)])
      let screen = transcriptScreen(ActivityRowView(row: row), actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("Completed"))
      #expect(try screen.shows("Explore auth"))
      try screen.clickControl(at: 0)
      #expect(log.entries == ["child child-1"])
    }

    @Test("A task marker names its status and task; a plan line is one line")
    func taskMarker() throws {
      let task = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .taskMarker, title: "Waiting for you on", summary: "Review the plan",
            status: "needs_input")))
      defer { task.close() }
      #expect(try task.shows("Waiting for you on Review the plan"))
      #expect(task.controlFrames.isEmpty)

      let plan = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .taskMarker, title: "Made a plan: Ship it \u{00B7} 2 tasks", status: "plan")))
      defer { plan.close() }
      #expect(try plan.shows("Made a plan: Ship it \u{00B7} 2 tasks"))
    }

    @Test("A settled thought previews its first line; an empty one is a flat header")
    func reasoningPreview() throws {
      let row = Fixture.activityRow(
        .reasoning, summary: "Planning the retry fix",
        details: [
          DetailSection(
            id: "summary", title: "Summary", text: "## **Planning** the retry fix\n\nDetails.")
        ])
      let settled = transcriptScreen(ActivityRowView(row: row))
      defer { settled.close() }
      #expect(try settled.shows("Thinking: Planning the retry fix"))
      #expect(try !settled.shows("Thought for"))
      #expect(try !settled.shows("Details."))
      try settled.clickControl(at: 0)
      #expect(try settled.shows("Details."))

      let empty = transcriptScreen(
        ActivityRowView(
          row: Fixture.activityRow(
            .reasoning, summary: "No public reasoning summary was provided.")))
      defer { empty.close() }
      #expect(try empty.shows("Thought for a few seconds"))
      #expect(empty.controlFrames.isEmpty)
    }

    private func origin(_ text: String = "Can you review PR 12?\nIt is small.") -> Row {
      Row(id: "m1", role: .user, text: text, originSessionId: "sess-peer")
    }

    @Test("Another session's message starts collapsed to its sender and first line, and opens")
    func sessionMessage() throws {
      let log = HostLog()
      var actions = ConversationActions()
      actions.sessionTitle = { $0 == "sess-peer" ? "Peer review" : nil }
      actions.openSession = { log.add("open \($0)") }
      let screen = transcriptScreen(
        MessageRowView(row: origin(), decoration: MessageDecoration()), actions: actions)
      defer { screen.close() }
      #expect(try screen.shows("From"))
      #expect(try screen.shows("@Peer review"))
      #expect(try screen.shows("Can you review PR 12?"))
      #expect(try !screen.shows("It is small."))
      // The sender opens its session; the preview, the bubble's last control, opens the message.
      let controls = screen.controlFrames.count
      try screen.clickControl(at: controls - 2)
      #expect(log.entries == ["open sess-peer"])
      try screen.clickControl(at: controls - 1)
      #expect(try screen.shows("It is small."))

      let unknown = transcriptScreen(
        MessageRowView(row: origin(), decoration: MessageDecoration()))
      defer { unknown.close() }
      #expect(try unknown.shows("another session"))
    }

    @Test("A text cell draws another session's message collapsed, then whole with its sender")
    func sessionMessageTextCell() throws {
      let row = textCellRow(origin())
      let style = textCellStyle(textCellEnvironment())
      let collapsed = try #require(TranscriptTableTextMessage.make(row, ramp: style.ramp))
      #expect(collapsed.originFold == .collapsed)
      #expect(collapsed.runs.isEmpty)
      #expect(
        collapsed.accessories
          == [.collapsedOrigin(sessionID: "sess-peer", preview: "Can you review PR 12?")])
      let open = try #require(
        TranscriptTableTextMessage.make(row, ramp: style.ramp, expandsOrigin: true))
      #expect(open.originFold == .expanded)
      #expect(open.accessories.first == .origin(sessionID: "sess-peer"))
      #expect(!open.runs.isEmpty)
      // The CLI style's band folds it, which its hosted row draws.
      let block = TranscriptTableRow(
        .block(
          CLIBlockEntry(
            block: .segment(.item(.message(origin()))), decorations: [:])))
      let palette = CLIPalette(theme: .nord, dark: true, increasedContrast: false)
      #expect(
        TranscriptTableCLIText.make(
          block, rendering: .styled, palette: palette, expansions: CLIWorkExpansions()) == nil)
    }
  }
#endif
