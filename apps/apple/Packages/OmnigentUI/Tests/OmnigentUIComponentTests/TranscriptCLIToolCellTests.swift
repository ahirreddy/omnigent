#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("CLI tool cells: edits, plans and exploring", .serialized)
  @MainActor
  struct TranscriptCLIToolCellTests {
    private typealias Fixture = TranscriptFixture

    init() {
      SystemSideEffects.reset()
    }

    private func edit(_ patch: String, title: String = "Edit", isFailure: Bool = false)
      -> ToolEntry
    {
      let call = Fixture.toolCall(
        "c", title: title, summary: "edit",
        details: [DetailSection(id: "arguments", title: "Arguments", text: patch)])
      return ToolEntry(
        call: call,
        result: isFailure
          ? Fixture.toolResult("r", callID: "c", output: "no match", isFailure: true) : nil)
    }

    @Test("An edit names its file and counts, and lists its changed lines under it")
    func editDiff() throws {
      let patch =
        "--- a/app.swift\n+++ b/app.swift\n@@ -7,2 +7,3 @@\n same\n-old\n+new\n+more\n"
        + "@@ -40 +41 @@\n-far\n+near\n"
      let screen = CLIToolFixture.screen([edit(patch)], rendering: .rich)
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Edited app.swift (+3 -2)"))
      for text in ["7", "same", "8", "old", "new", "9", "more", "-", "+", "\u{22EE}", "41"] {
        #expect(shown.contains(text), "\(text)")
      }
      // Rich rendering opens the chat's diff card in place of the lines.
      #expect(!shown.contains("-old"))
      let menu = try #require(try screen.firstContextMenu())
      try screen.choose("Show output", in: menu)
      #expect(try screen.shownText().contains("-old"))
    }

    @Test("A long edit stops after a screenful until asked for the rest")
    func longEdit() throws {
      let added = (1...20).map { "+line\($0)" }.joined(separator: "\n")
      let screen = CLIToolFixture.screen([
        edit("*** Begin Patch\n*** Add File: new.txt\n\(added)\n*** End Patch")
      ])
      defer { screen.close() }
      #expect(try screen.shows("Added new.txt (+20 -0)"))
      #expect(try screen.shows("line12"))
      #expect(try !screen.shows("line13"))
      #expect(try screen.shows("\u{2026} +8 lines"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(try screen.shows("line20"))
    }

    @Test("An edit of several files lists each under its own path; a failed one says why")
    func editFiles() throws {
      let patch = """
        *** Begin Patch
        *** Update File: a.txt
        @@
        -one
        +one changed
        *** Delete File: b.txt
        *** End Patch
        """
      let screen = CLIToolFixture.screen([edit(patch, title: "apply_patch")])
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Edited 2 files (+1 -1)"))
      #expect(shown.contains("\u{2514} a.txt (+1 -1)"))
      #expect(shown.contains("\u{2514} b.txt (+0 -0)"))

      let failed = CLIToolFixture.screen([edit(patch, isFailure: true)])
      defer { failed.close() }
      #expect(try failed.shows("Failed to edit 2 files"))
      #expect(try failed.shows("no match"))
      #expect(try !failed.shows("one changed"))

      let running = CLIToolFixture.screen([
        ToolEntry(
          call: Fixture.toolCall("c", title: "Edit", summary: "path: a.txt", status: "running"),
          result: nil)
      ])
      defer { running.close() }
      #expect(try running.shows("Editing a.txt"))
    }

    @Test("A plan update lists its note and its steps")
    func plan() throws {
      let arguments = """
        explanation: Small steps
        plan: status: completed
        step: Read it
        status: in_progress
        step: Change it
        status: pending
        step: Test it
        """
      let screen = CLIToolFixture.screen([
        CLIToolFixture.entry(title: "update_plan", summary: arguments, output: "ok")
      ])
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Updated Plan"))
      #expect(shown.contains("Small steps"))
      #expect(shown.contains("\u{2714} Read it"))
      #expect(shown.contains("\u{25A1} Change it"))
      #expect(shown.contains("\u{25A1} Test it"))
      #expect(!shown.contains("ok"))

      let bare = CLIToolFixture.screen([
        CLIToolFixture.entry(title: "TodoWrite", summary: "todos: content: Only\nstatus: done")
      ])
      defer { bare.close() }
      #expect(try bare.shows("\u{2714} Only"))
    }

    @Test("Reads, searches and listings gather under Explored, reads in a row on one line")
    func explored() throws {
      let screen = CLIToolFixture.screen([
        CLIToolFixture.entry(
          "a", title: "Read", summary: "file_path: src/a.swift", output: "alpha"),
        CLIToolFixture.entry("b", title: "Read", summary: "file_path: src/b.swift", output: nil),
        CLIToolFixture.entry(
          "c", title: "Read", summary: "file_path: src/a.swift", output: "again"),
        CLIToolFixture.entry("d", title: "Grep", summary: "path: src\npattern: needle"),
        CLIToolFixture.entry("e", title: "ls", summary: ""),
        CLIToolFixture.entry(
          "f", title: "Read", summary: "gone.swift", output: "missing", isFailure: true),
        CLIToolFixture.entry("g", title: "Bash", summary: "make"),
      ])
      defer { screen.close() }
      let shown = try screen.shownText()
      #expect(shown.contains("Explored"))
      #expect(shown.contains("Read a.swift, b.swift"))
      #expect(shown.contains("Search needle in src"))
      #expect(shown.contains("List ."))
      #expect(shown.contains("Read gone.swift (failed)"))
      #expect(shown.contains("Ran make"))
      #expect(try !screen.shows("alpha"))

      // The reads' line opens every output it stands for, and copies them together.
      let menu = try #require(try screen.contextMenu(offering: "Copy output"))
      try screen.choose("Copy input", in: menu)
      #expect(
        copiedText() == "file_path: src/a.swift\nfile_path: src/b.swift\nfile_path: src/a.swift")
      try screen.choose("Copy output", in: menu)
      #expect(copiedText() == "alpha\nagain")
      try screen.choose("Show output", in: menu)
      #expect(try screen.shows("alpha"))
      #expect(try screen.shows("(no output)"))
    }

    @Test("A cell still exploring says so")
    func exploring() throws {
      let screen = CLIToolFixture.screen([
        CLIToolFixture.entry(title: "Read", summary: "a.swift", status: "running", output: nil)
      ])
      defer { screen.close() }
      #expect(try screen.shows("Exploring"))
    }
  }
#endif
