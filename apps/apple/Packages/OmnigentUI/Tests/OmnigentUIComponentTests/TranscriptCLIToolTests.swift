#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI tool lines", .serialized)
  @MainActor
  struct TranscriptCLIToolTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func entry(
      title: String = "Bash", summary: String = "ls -la", status: String? = "completed",
      output: String? = "total 0", isFailure: Bool = false
    ) -> ToolEntry {
      ToolEntry(
        call: Fixture.toolCall("c", title: title, summary: summary, status: status),
        result: output.map {
          Fixture.toolResult("r", callID: "c", output: $0, isFailure: isFailure)
        })
    }

    private func tools(_ entries: [ToolEntry], rendering: OutputRendering = .styled)
      -> OffscreenWindow<AnyView>
    {
      transcriptScreen(
        CLIToolLines(entries: entries)
          .transcriptAppearance(TranscriptAppearance(style: .cli, outputRendering: rendering)))
    }

    @Test("A line's verb comes from its tool, with the subject in backticks")
    func verbs() throws {
      let cases: [(String, String)] = [
        ("Bash", "Ran `s`"), ("Read", "Read `s`"), ("Edit", "Edited `s`"), ("Grep", "Searched `s`"),
        ("ls", "Listed `s`"), ("Custom", "Called Custom `s`"),
      ]
      for (title, expected) in cases {
        let screen = tools([entry(title: title, summary: "s")])
        defer { screen.close() }
        #expect(try screen.shows(expected), "\(title)")
      }
    }

    @Test("A running or failed tool says so, and a blank summary falls back to its name")
    func states() throws {
      let running = tools([entry(status: "in_progress", output: nil)])
      defer { running.close() }
      #expect(try running.shows("Running `ls -la`"))

      let failed = tools([entry(output: "boom", isFailure: true)])
      defer { failed.close() }
      #expect(try failed.shows("Failed `ls -la`"))

      let blank = tools([entry(summary: "")])
      defer { blank.close() }
      #expect(try blank.shows("Ran `Bash`"))

      let multiline = tools([entry(summary: "first\nsecond")])
      defer { multiline.close() }
      #expect(try multiline.shows("Ran `first`"))
    }

    @Test("Show output opens the output, Hide output closes it, and both copies work")
    func output() throws {
      let screen = tools([entry(summary: "first\nsecond", output: "the output")])
      defer { screen.close() }
      #expect(try !screen.shows("the output"))
      let menu = try #require(try screen.firstContextMenu())
      #expect(titles(of: menu) == ["Show output", "Copy input", "Copy output"])
      try screen.choose("Copy input", in: menu)
      #expect(copiedText() == "first\nsecond")
      try screen.choose("Copy output", in: menu)
      #expect(copiedText() == "the output")
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("the output"))
      #expect(try screen.shows("second"))
      let open = try #require(try screen.firstContextMenu())
      try screen.choose("Hide output", in: open)
      #expect(try !screen.shows("the output"))
    }

    @Test("A finished tool with no output says that when opened; a running one doesn't")
    func noOutput() throws {
      let finished = tools([ToolEntry(call: Fixture.toolCall("c", summary: ""), result: nil)])
      defer { finished.close() }
      let menu = try #require(try finished.firstContextMenu())
      #expect(titles(of: menu) == ["Show output"])
      try finished.choose("Show output", in: menu)
      #expect(try finished.shows("(no output)"))

      let running = tools([entry(status: "in_progress", output: nil)])
      defer { running.close() }
      let runningMenu = try #require(try running.firstContextMenu())
      try running.choose("Show output", in: runningMenu)
      #expect(try !running.shows("(no output)"))
    }

    @Test("Rich rendering opens the call's and the result's sections, with attachments")
    func richOutput() throws {
      let attachment = Attachment(id: "f", kind: .file, title: "report.pdf")
      let call = Fixture.toolCall(
        "c", details: [DetailSection(id: "arguments", title: "Arguments", text: "the args")],
        attachments: [attachment])
      let screen = tools(
        [ToolEntry(call: call, result: Fixture.toolResult("r", callID: "c"))], rendering: .rich)
      defer { screen.close() }
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("the args"))
      #expect(try screen.shows("report.pdf"))
    }

    @Test("An edit names its files and its added and removed lines")
    func editDiff() throws {
      let patch = "--- a/app.swift\n+++ b/app.swift\n@@ -1,2 +1,2 @@\n-old\n+new\n+more\n"
      let call = Fixture.toolCall(
        "c", title: "Edit", summary: "edit",
        details: [DetailSection(id: "arguments", title: "Arguments", text: patch)])
      let screen = tools([ToolEntry(call: call, result: nil)], rendering: .rich)
      defer { screen.close() }
      #expect(try screen.shows("Edited `app.swift` (+2 \u{2212}1)"))
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("old"))
    }

    @Test("Agents log every start, then each finish, and only a finish copies its result")
    func agentLines() throws {
      let done = entry(title: "spawn_agent", summary: "/root/one", output: "its answer")
      let screen = tools([done])
      defer { screen.close() }
      #expect(try screen.shows("Started `/root/one`"))
      #expect(try screen.shows("Completed `/root/one`"))
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Copy result", in: menu)
      #expect(copiedText() == "its answer")

      let failed = tools([entry(title: "agent", summary: "", output: "bad", isFailure: true)])
      defer { failed.close() }
      #expect(try failed.shows("Failed `agent`"))

      let running = tools([entry(title: "task", summary: "s", status: "in_progress", output: nil)])
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
    }

    @Test("A line's actions appear on hover and work from the cluster")
    func hoverCluster() throws {
      let screen = tools([entry(summary: "the input")])
      defer { screen.close() }
      let resting = screen.controlFrames.count
      let line = try #require(screen.controlFrames.first)
      try screen.hover(CGPoint(x: line.midX, y: line.midY))
      let frames = screen.controlFrames
      #expect(frames.count == resting + 3)
      try screen.clickControl(at: 1)
      try screen.endHover()
      #expect(screen.controlFrames.count == resting)
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
