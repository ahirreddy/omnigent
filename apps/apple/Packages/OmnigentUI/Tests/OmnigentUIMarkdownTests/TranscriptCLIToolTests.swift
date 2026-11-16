#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A tool call with its result, and the CLI cells that draw a run of them.
  @MainActor
  enum CLIToolFixture {
    static func entry(
      _ id: String = "c", title: String = "Bash", summary: String = "ls -la",
      status: String? = "completed", output: String? = "total 0", isFailure: Bool = false
    ) -> ToolEntry {
      ToolEntry(
        call: TranscriptFixture.toolCall(id, title: title, summary: summary, status: status),
        result: output.map {
          TranscriptFixture.toolResult("\(id)-result", callID: id, output: $0, isFailure: isFailure)
        })
    }

    static func screen(_ entries: [ToolEntry], rendering: OutputRendering = .styled)
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(
        CLIToolLines(entries: entries)
          .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering)))
    }
  }

  @Suite("CLI tool cells", .serialized)
  @MainActor
  struct TranscriptCLIToolTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    @Test("A cell's header says what the call did, with no backticks or argument keys")
    func headers() throws {
      let cases: [(ToolEntry, String)] = [
        (CLIToolFixture.entry(title: "Bash", summary: "s"), "Ran s"),
        (CLIToolFixture.entry(title: "Custom", summary: "s"), "Called Custom(s)"),
        (CLIToolFixture.entry(title: "Custom", summary: ""), "Called Custom"),
        (
          CLIToolFixture.entry(title: "mcp__docs__find", summary: "limit: 3\nquery: q"),
          "Called docs.find(limit: 3, query: q)"
        ),
        (CLIToolFixture.entry(title: "Edit", summary: "file_path: a.swift"), "Edited a.swift"),
        (CLIToolFixture.entry(title: "Write", summary: ""), "Edited files"),
      ]
      for (entry, expected) in cases {
        let screen = CLIToolFixture.screen([entry])
        defer { screen.close() }
        let shown = try screen.shownText()
        #expect(shown.contains(expected), "\(shown)")
      }
    }

    @Test("A command shows without its login shell, its later lines behind a bar")
    func commandLines() throws {
      let script = "python3 - <<'PY'\nprint(1)\nprint(2)\nprint(3)\nprint(4)\nPY"
      let screen = CLIToolFixture.screen([
        CLIToolFixture.entry(summary: "command: /usr/bin/zsh -lc \"\(script)\"\nworkdir: /repo")
      ])
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Ran python3 - <<'PY'"))
      #expect(shown.contains("print(2)"))
      #expect(shown.contains("\u{2026} +3 lines"))
      #expect(!shown.contains { $0.contains("zsh") || $0.contains("command:") })
      #expect(try !screen.shows("print(4)"))
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Copy input", in: menu)
      #expect(copiedText() == script)
      // The count of hidden lines is the button that shows them.
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(try screen.shows("print(4)"))
    }

    @Test("A running or failed command says so, and a blank one falls back to its tool")
    func states() throws {
      let running = CLIToolFixture.screen([CLIToolFixture.entry(status: "in_progress", output: nil)]
      )
      defer { running.close() }
      #expect(try running.shows("Running ls -la"))
      #expect(try !running.shows("(no output)"))

      // A failure keeps "Ran" and its output: its marker turns red, as the Codex CLI marks it.
      let failed = CLIToolFixture.screen([CLIToolFixture.entry(output: "boom", isFailure: true)])
      defer { failed.close() }
      #expect(try failed.shows("Ran ls -la"))
      #expect(try failed.shows("boom"))

      let blank = CLIToolFixture.screen([CLIToolFixture.entry(summary: "")])
      defer { blank.close() }
      #expect(try blank.shows("Ran Bash"))
    }

    @Test("Output shows its first lines; Show output opens the rest, and both copies work")
    func output() throws {
      let lines = (1...5).map { "line\($0)" }.joined(separator: "\n")
      let screen = CLIToolFixture.screen([CLIToolFixture.entry(output: lines + "\n")])
      defer { screen.close() }
      #expect(try screen.shows("line3"))
      #expect(try !screen.shows("line4"))
      #expect(try screen.shows("\u{2026} +2 lines"))
      let menu = try #require(try screen.firstContextMenu())
      #expect(titles(of: menu) == ["Show output", "Copy input", "Copy output"])
      try screen.choose("Copy input", in: menu)
      #expect(copiedText() == "ls -la")
      try screen.choose("Copy output", in: menu)
      #expect(copiedText() == lines)
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("line5"))
      let open = try #require(try screen.firstContextMenu())
      try screen.choose("Hide output", in: open)
      #expect(try !screen.shows("line5"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(try screen.shows("line5"))
    }

    @Test("A finished call with no output says that; a running one doesn't")
    func noOutput() throws {
      let finished = CLIToolFixture.screen([
        ToolEntry(call: Fixture.toolCall("c", summary: ""), result: nil)
      ])
      defer { finished.close() }
      #expect(try finished.shows("(no output)"))
      let menu = try #require(try finished.firstContextMenu())
      #expect(titles(of: menu) == ["Show output"])

      let orphan = CLIToolFixture.screen([
        ToolEntry(call: nil, result: Fixture.toolResult("r", callID: "c"))
      ])
      defer { orphan.close() }
      #expect(try orphan.shownText().contains("Result"))
      #expect(try orphan.shows("total 0"))
    }

    @Test("Rich rendering opens the call's and the result's sections, with attachments")
    func richOutput() throws {
      let attachment = Attachment(id: "f", kind: .file, title: "report.pdf")
      let call = Fixture.toolCall(
        "c", details: [DetailSection(id: "arguments", title: "Arguments", text: "the args")],
        attachments: [attachment])
      let screen = CLIToolFixture.screen(
        [ToolEntry(call: call, result: Fixture.toolResult("r", callID: "c"))], rendering: .rich)
      defer { screen.close() }
      #expect(try !screen.shows("report.pdf"))
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("report.pdf"))
    }

    @Test("Agents log every start, then each finish, and only a finish copies its result")
    func agentLines() throws {
      let done = CLIToolFixture.entry(
        title: "spawn_agent", summary: "/root/one", output: "its answer")
      let screen = CLIToolFixture.screen([done])
      defer { screen.close() }
      #expect(try screen.shows("Started `/root/one`"))
      #expect(try screen.shows("Completed `/root/one`"))
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Copy result", in: menu)
      #expect(copiedText() == "its answer")

      let failed = CLIToolFixture.screen([
        CLIToolFixture.entry(title: "agent", summary: "", output: "bad", isFailure: true)
      ])
      defer { failed.close() }
      #expect(try failed.shows("Failed `agent`"))

      let running = CLIToolFixture.screen([
        CLIToolFixture.entry(title: "task", summary: "s", status: "in_progress", output: nil)
      ])
      defer { running.close() }
      #expect(try running.shows("Started `s`"))
      #expect(try !running.shows("Completed"))
      #expect(try running.firstContextMenu() == nil)
    }

    @Test("Long detail text stops at its limit until asked for the rest")
    func detailLimit() throws {
      let text = (0..<8).map { "line\($0)" }.joined(separator: "\n")
      let screen = transcriptScreen(CLIDetailText(text: text, maxLines: 3))
      defer { screen.close() }
      #expect(try screen.shows("\u{2026} +5 lines"))
      #expect(try !screen.shows("line7"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("line7"))
      #expect(try !screen.shows("+5 lines"))
      #expect(CLIOutputTree.more(1) == "\u{2026} +1 line")
    }

    @Test("A cell's actions stay off its text under the pointer, and are in its menu")
    func actionsInTheMenuNotOnHover() throws {
      let screen = CLIToolFixture.screen([CLIToolFixture.entry(summary: "the input")])
      defer { screen.close() }
      restKeyboard(screen)
      let resting = screen.controlFrames.count
      let line = try #require(screen.controlFrames.first)
      try screen.hover(CGPoint(x: line.midX, y: line.midY))
      #expect(screen.controlFrames.count == resting)
      try screen.endHover()
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: line.midX, y: line.midY)))
      #expect(menu.item(withTitle: "Show output") != nil)
      #expect(menu.item(withTitle: "Copy input") != nil)
    }

    @Test("On touch one action is a button, and several open from a menu")
    func touchActions() throws {
      let log = HostLog()
      let first = CLIAction(title: "One", systemImage: "a", identifier: "one") { log.add("one") }
      let second = CLIAction(title: "Two", systemImage: "b", identifier: "two") { log.add("two") }
      let single = transcriptScreen(CLITouchActionsButton(actions: [first]))
      defer { single.close() }
      try single.clickControl(at: 0)
      #expect(log.entries == ["one"])

      let several = transcriptScreen(CLITouchActionsButton(actions: [first, second]))
      defer { several.close() }
      let menu = try several.openMenu(CGPoint(x: 14, y: 8))
      #expect(titles(of: menu) == ["One", "Two"])
      try several.choose("Two", in: menu)
      #expect(log.entries == ["one", "two"])
    }
  }
#endif
