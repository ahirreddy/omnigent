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
      try screen.hover(CGPoint(x: 100, y: 8))
      // The fold button, then the first line's Show output, Copy input and Copy output.
      let frames = screen.controlFrames
      let cluster = Array(frames.prefix(4))
      for (index, frame) in cluster.enumerated() {
        for other in cluster[(index + 1)...] { #expect(!frame.intersects(other), "\(cluster)") }
      }
      try screen.clickControl(at: 3)
      #expect(copiedText() == "total 0")
      #expect(try !screen.shows("Ran 2 shell commands"))

      try screen.clickControl(at: 0)
      #expect(try screen.shows("Ran 2 shell commands"))
      #expect(try !screen.shows("Ran `ls -la`"))
      try clickFoldButton(screen)
      #expect(try screen.shows("Ran `ls -la`"))
    }

    /// With nothing else revealed, the fold button is the narrowest control: the rest is its host.
    private func clickFoldButton(_ screen: OffscreenWindow<AnyView>) throws {
      let button = try #require(screen.controlFrames.min { $0.width < $1.width })
      try screen.click(CGPoint(x: button.midX, y: button.midY))
    }

    @Test("A work group with no tools says it worked; a live one can't be folded")
    func workGroupEdges() throws {
      let row = Fixture.activityRow(.compaction, title: "Compacted")
      let settled = transcriptScreen(
        CLIWorkGroup(id: "w", items: [.activity(row)], isLive: false, decorations: [:]))
      defer { settled.close() }
      try settled.hover(CGPoint(x: 100, y: 8))
      try clickFoldButton(settled)
      #expect(try settled.shows("Worked \u{2026}"))

      let live = transcriptScreen(
        CLIWorkGroup(id: "w", items: [.activity(row)], isLive: true, decorations: [:]))
      defer { live.close() }
      try live.hover(CGPoint(x: 100, y: 8))
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

    @Test("Sub-agents read as lifecycle lines, each opening its transcript")
    func subagentLines() throws {
      var opened: [String] = []
      var actions = ConversationActions()
      actions.openChild = { opened.append($0) }
      var state = PreviewData.conversation
      state.rows = []
      state.sections = [
        EventSection(id: "child-a", title: "Done one", summary: "Ready", sessionId: "a"),
        EventSection(id: "child-b", title: "Bad one", summary: "Failed", sessionId: "b"),
      ]
      let screen = transcriptScreen(CLISubagentLines(state: state, actions: actions))
      defer { screen.close() }
      #expect(try screen.shows("`Done one`"))
      #expect(try screen.shows("`Bad one`"))
      let menu = try #require(try screen.firstContextMenu())
      let open = try #require(titles(of: menu).first { $0.hasPrefix("Open ") })
      try screen.choose(open, in: menu)
      #expect(opened.count == 1)
    }

    @Test("No children, no lines")
    func noSubagents() throws {
      var state = PreviewData.conversation
      state.sections = []
      let screen = transcriptScreen(CLISubagentLines(state: state, actions: ConversationActions()))
      defer { screen.close() }
      #expect(screen.controlFrames.isEmpty)
    }
  }
#endif
