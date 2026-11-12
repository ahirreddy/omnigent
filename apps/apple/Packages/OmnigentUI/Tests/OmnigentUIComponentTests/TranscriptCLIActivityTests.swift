#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI activity lines", .serialized)
  @MainActor
  struct TranscriptCLIActivityTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func line(
      _ row: Row, actions: ConversationActions = ConversationActions(),
      rendering: OutputRendering = .styled
    ) -> OffscreenWindow<AnyView> {
      transcriptScreen(
        CLIActivityLine(row: row)
          .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering)),
        actions: actions)
    }

    @Test("Each kind's line says what happened, the way a terminal does")
    func lineText() throws {
      let cases: [(Row, String)] = [
        (Fixture.activityRow(.reasoning, isStreaming: true), "Thinking\u{2026}"),
        (Fixture.activityRow(.reasoning), "Thought"),
        (
          Fixture.activityRow(
            .terminal, summary: "fallback",
            details: [DetailSection(id: "input", title: "Input", text: "make test")]),
          "$ make test"
        ),
        (Fixture.activityRow(.terminal, summary: "ls"), "$ ls"),
        (Fixture.activityRow(.error, summary: "It broke", isFailure: true), "Error: It broke"),
        (Fixture.activityRow(.error, title: "Only title", isFailure: true), "Error: Only title"),
        (Fixture.activityRow(.command, title: "Run", summary: "/x"), "Run /x"),
        (
          Fixture.activityRow(.retry, title: "Retrying", status: "in_progress"),
          "Retrying \u{00B7} in progress"
        ),
        (Fixture.activityRow(.compaction, title: "Compacted", status: ""), "Compacted"),
        (Fixture.activityRow(.file, title: "Denied", status: "failed", isFailure: true), "Denied"),
      ]
      for (row, expected) in cases {
        let screen = line(row)
        defer { screen.close() }
        #expect(try screen.shows(expected), "\(expected)")
      }
    }

    @Test("A failed row leaves its status out of the line")
    func failureHidesStatus() throws {
      let screen = line(
        Fixture.activityRow(.file, title: "Denied", status: "blocked", isFailure: true))
      defer { screen.close() }
      #expect(try screen.shows("Denied"))
      #expect(try !screen.shows("blocked"))
    }

    @Test("Side questions, unknown items and rows without activity keep their native rows")
    func nativeRows() throws {
      let unknown = line(Fixture.activityRow(.unknown, title: "Mystery"))
      defer { unknown.close() }
      #expect(try unknown.shows("Mystery"))

      let bare = line(Row(id: "row", role: .tool, text: "Bare text"))
      defer { bare.close() }
      #expect(try bare.shows("Bare text"))
    }

    @Test("Show details opens the reasoning, and Hide details closes it")
    func reasoningDetails() throws {
      let row = Fixture.activityRow(.reasoning, summary: "Weighed the options")
      let screen = line(row)
      defer { screen.close() }
      #expect(try !screen.shows("Weighed the options"))
      let closed = try #require(try screen.firstContextMenu())
      try screen.choose("Show details", in: closed)
      #expect(try screen.shows("Weighed the options"))
      let open = try #require(try screen.firstContextMenu())
      try screen.choose("Hide details", in: open)
      #expect(try !screen.shows("Weighed the options"))
    }

    @Test("A command's output opens with its errors, and the copy is the command")
    func terminalDetails() throws {
      let row = Fixture.activityRow(
        .terminal,
        details: [
          DetailSection(id: "input", title: "Input", text: "make"),
          DetailSection(id: "stdout", title: "Out", text: "built"),
          DetailSection(id: "stderr", title: "Err", text: "warned"),
        ])
      let screen = line(row)
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show details", in: menu)
      #expect(try screen.shows("built"))
      #expect(try screen.shows("warned"))
      try screen.choose("Copy", in: menu)
      #expect(copiedText() == "make")
    }

    @Test("A row with nothing to show or copy offers no actions")
    func noActions() throws {
      let cases = [
        Fixture.activityRow(.terminal),
        Fixture.activityRow(.compaction, title: "Compacted"),
        Fixture.activityRow(.reasoning),
      ]
      for row in cases {
        let screen = line(row)
        defer { screen.close() }
        #expect(try screen.firstContextMenu() == nil)
      }
    }

    @Test("Generic details follow the output rendering")
    func genericDetails() throws {
      let details = [DetailSection(id: "d", title: "Section", text: "Inside")]
      for rendering in OutputRendering.allCases {
        let screen = line(
          Fixture.activityRow(.resource, title: "Res", details: details), rendering: rendering)
        defer { screen.close() }
        let menu = try #require(try screen.firstContextMenu())
        try screen.choose("Show details", in: menu)
        #expect(try screen.shows("Inside"), "\(rendering)")
      }
    }

    @Test("An error can be copied and retried, and the button is there without hovering")
    func errorRecovery() throws {
      var retried: [String] = []
      var actions = ConversationActions()
      actions.retryFailedTurn = { retried.append($0.id) }
      let row = Fixture.activityRow(
        .error, id: "failed", summary: "It broke", isFailure: true, recovery: .continue)
      let title = FailureRecovery.continue.title
      let screen = line(row, actions: actions)
      defer { screen.close() }
      #expect(try screen.shows(title))
      let frames = screen.controlFrames
      try screen.clickControl(at: frames.count - 1)
      #expect(retried == ["failed"])
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Copy error", in: menu)
      #expect(copiedText() == "It broke")

      let noHost = line(row)
      defer { noHost.close() }
      #expect(try noHost.shows("It broke"))
      #expect(try !noHost.shows(title))
    }

    @Test("Copy prefers the row's own text over its summary")
    func copyText() throws {
      var row = Fixture.activityRow(.file, title: "File", summary: "Summary")
      row.text = "The whole text"
      let screen = line(row)
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Copy", in: menu)
      #expect(copiedText() == "The whole text")
    }

    @Test("Each kind's details have a toggle")
    func everyKindToggles() throws {
      let details = [DetailSection(id: "summary", title: "S", text: "Inner")]
      for kind in [ActivityKind.compaction, .retry, .file, .error] {
        let screen = line(Fixture.activityRow(kind, title: "T", details: details))
        defer { screen.close() }
        let menu = try #require(try screen.firstContextMenu())
        #expect(titles(of: menu).contains("Show details"), "\(kind)")
      }
    }

    @Test("A settled turn's work folds into one summary line, and opens again")
    func workGroupFold() throws {
      let entries = [
        ToolEntry(call: Fixture.toolCall("a"), result: Fixture.toolResult("ar", callID: "a")),
        ToolEntry(call: Fixture.toolCall("b"), result: Fixture.toolResult("br", callID: "b")),
      ]
      let screen = transcriptScreen(
        CLIWorkGroup(
          id: "w", items: [.tools(id: "t", entries: entries)], isLive: false, decorations: [:]))
      defer { screen.close() }
      #expect(try screen.shows("Ran `ls -la`"))
      // The pointer resting on a line puts nothing over its text.
      restKeyboard(screen)
      let resting = screen.controlFrames.count
      try screen.hover(CGPoint(x: 100, y: 8))
      #expect(screen.controlFrames.count == resting)
      try screen.endHover()

      // The line's menu copies its output; the group's folds it and opens it again.
      let line = try #require(try screen.contextMenu(offering: "Copy output"))
      #expect(line.item(withTitle: "Show output") != nil)
      try screen.choose("Copy output", in: line)
      #expect(copiedText() == "total 0")
      #expect(try !screen.shows("Ran 2 shell commands"))

      try screen.choose(
        "Collapse work", in: try #require(try screen.contextMenu(offering: "Collapse work")))
      #expect(try screen.shows("Ran 2 shell commands"))
      #expect(try !screen.shows("Ran `ls -la`"))
      try screen.choose(
        "Expand work", in: try #require(try screen.contextMenu(offering: "Expand work")))
      #expect(try screen.shows("Ran `ls -la`"))
    }

    @Test("A work group with no tools says it worked; a live one can't be folded")
    func workGroupEdges() throws {
      let row = Fixture.activityRow(.compaction, title: "Compacted")
      let settled = transcriptScreen(
        CLIWorkGroup(id: "w", items: [.activity(row)], isLive: false, decorations: [:]))
      defer { settled.close() }
      try settled.choose(
        "Collapse work", in: try #require(try settled.contextMenu(offering: "Collapse work")))
      #expect(try settled.shows("Worked \u{2026}"))

      let live = transcriptScreen(
        CLIWorkGroup(id: "w", items: [.activity(row)], isLive: true, decorations: [:]))
      defer { live.close() }
      #expect(try live.contextMenu(offering: "Collapse work") == nil)
      #expect(live.controlFrames.isEmpty)
      #expect(try live.shows("Compacted"))
    }

    @Test("The working line shows the time, the interrupt hint, or what it waits on")
    func workingLine() throws {
      let blocked = transcriptScreen(CLIWorkingLine(isBlocked: true, startedAt: Date()))
      defer { blocked.close() }
      #expect(try blocked.shows("Waiting for your response to the request below."))

      let bare = transcriptScreen(
        CLIWorkingLine(isBlocked: false).environment(\.composerLayoutStyle, .touch))
      defer { bare.close() }
      #expect(try bare.shows("Working"))
      #expect(try !bare.shows("("))

      let timed = transcriptScreen(
        CLIWorkingLine(isBlocked: false, startedAt: Date().addingTimeInterval(-12))
          .environment(\.composerLayoutStyle, .card))
      defer { timed.close() }
      #expect(try timed.shows("esc to interrupt"))
    }

    @Test("The CLI transcript ends with its rows: no line per sub-agent and no agents bar")
    func noSubagentBlock() throws {
      var state = PreviewData.conversation
      state.sections = [
        PreviewData.childSection("a", title: "Child a", state: .running),
        PreviewData.childSection("b", title: "Child b", state: .ready),
      ]
      func screen(_ style: TranscriptStyle) -> OffscreenWindow<AnyView> {
        transcriptScreen(
          TranscriptView(state: state, actions: ConversationActions())
            .transcriptAppearance(TranscriptAppearance(style: style)), height: 900)
      }
      func namesAgents(_ screen: OffscreenWindow<AnyView>) throws -> Bool {
        try screen.shownText().contains { $0.contains("Child a") || $0.contains("2 agents") }
      }
      let cli = screen(.cli)
      defer { cli.close() }
      #expect(try !namesAgents(cli))
      // The chat style keeps its bar while an agent is at work.
      let chat = screen(.chat)
      defer { chat.close() }
      #expect(try namesAgents(chat))
    }
  }

#endif
