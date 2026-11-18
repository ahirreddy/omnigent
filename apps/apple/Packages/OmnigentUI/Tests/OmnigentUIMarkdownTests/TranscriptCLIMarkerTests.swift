#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A thought's preview, runtime notices and sub-agent and task markers as CLI lines.
  @Suite("CLI marker lines", .serialized)
  @MainActor
  struct TranscriptCLIMarkerTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func line(
      _ row: Row, actions: ConversationActions = ConversationActions()
    ) -> OffscreenWindow<AnyView> {
      transcriptScreen(
        CLIActivityLine(row: row)
          .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: .styled)),
        actions: actions)
    }

    @Test("Show details opens the reasoning, and Hide details closes it")
    func reasoningDetails() throws {
      // As the core sends a settled thought: its first line as the summary, its text in full.
      let row = Fixture.activityRow(
        .reasoning, summary: "Weighed the options.",
        details: [
          DetailSection(
            id: "summary", title: "Summary", text: "Weighed the options.\nPicked the cheap one.")
        ])
      let screen = line(row)
      defer { screen.close() }
      #expect(try screen.shows("Thinking: Weighed the options."))
      #expect(try !screen.shows("Picked the cheap one."))
      let closed = try #require(try screen.firstContextMenu())
      try screen.choose("Show details", in: closed)
      #expect(try screen.shows("Picked the cheap one."))
      let open = try #require(try screen.firstContextMenu())
      try screen.choose("Hide details", in: open)
      #expect(try !screen.shows("Picked the cheap one."))
    }

    @Test("Notices and markers read as the chat's markers, and a sub-agent's opens its session")
    func markerLines() throws {
      let notice = Fixture.activityRow(
        .systemNotice, title: "Timer t1 fired", summary: "note: check", status: "timer_fired",
        details: [DetailSection(id: "body", title: "Details", text: "note: check")])
      let subagent = Fixture.activityRow(
        .subagentMarker, title: "Failed", summary: "Explore auth", status: "returned",
        details: [DetailSection(id: "session", title: "Session", text: "child-1")])
      let task = Fixture.activityRow(
        .taskMarker, title: "Completed", summary: "Write the tests", status: "done")
      for (row, expected) in [
        (notice, "System: Timer t1 fired"), (subagent, "Failed Explore auth"),
        (task, "Completed Write the tests"),
      ] {
        let screen = line(row)
        defer { screen.close() }
        #expect(try screen.shows(expected), "\(expected)")
      }
      let log = HostLog()
      var actions = ConversationActions()
      actions.openChild = { log.add("open \($0)") }
      let screen = line(subagent, actions: actions)
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      #expect(titles(of: menu) == ["Open Explore auth", "Copy"])
      try screen.choose("Open Explore auth", in: menu)
      #expect(log.entries == ["open child-1"])
      let opened = line(notice)
      defer { opened.close() }
      #expect(try !opened.shows("note: check"))
      try opened.choose("Show details", in: try #require(try opened.firstContextMenu()))
      #expect(try opened.shows("note: check"))
    }
  }
#endif
