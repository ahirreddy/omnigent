#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Transcript tool steps", .serialized)
  @MainActor
  struct TranscriptToolStepTests {
    private typealias Fixture = TranscriptFixture

    @Test("A tool step opens to its input and output, and closes again")
    func stepOpensAndCloses() throws {
      let entry = ToolEntry(
        call: Fixture.toolCall(
          "call",
          details: [DetailSection(id: "arguments", title: "Input", text: "ls", isCode: true)]),
        result: Fixture.toolResult("result", callID: "call", output: "file.txt"))
      let screen = transcriptScreen(ToolRowView(entry: entry))
      defer { screen.close() }
      let closedControls = screen.controlFrames.count
      #expect(try screen.shows("Bash"))
      #expect(try !screen.shows("file.txt"))

      try screen.clickControl(at: 0)
      #expect(try screen.shows("file.txt"))
      #expect(try screen.shows("ls -la"))
      #expect(screen.controlFrames.count > closedControls)

      try screen.clickControl(at: 0)
      #expect(try !screen.shows("file.txt"))
      #expect(screen.controlFrames.count == closedControls)
    }

    @Test("A finished call with no result says so; a running one doesn't")
    func noOutput() throws {
      let finished = transcriptScreen(
        ToolRowView(entry: ToolEntry(call: Fixture.toolCall("call"), result: nil)))
      defer { finished.close() }
      try finished.clickControl(at: 0)
      #expect(try finished.shows("No output recorded."))

      let running = transcriptScreen(
        ToolRowView(
          entry: ToolEntry(call: Fixture.toolCall("call", status: "running"), result: nil)))
      defer { running.close() }
      try running.clickControl(at: 0)
      #expect(try !running.shows("No output recorded."))
    }

    @Test("Several calls fold under one summary once settled, open while one runs")
    func groupFolds() throws {
      let settled = [
        ToolEntry(call: Fixture.toolCall("a", title: "Read"), result: nil),
        ToolEntry(call: Fixture.toolCall("b", title: "Bash"), result: nil),
      ]
      let screen = transcriptScreen(ToolGroupView(entries: settled))
      defer { screen.close() }
      #expect(try screen.shows("Ran 1 shell command, read 1 file"))
      #expect(try !screen.shows("Read"))
      try screen.clickControl(at: 0)
      #expect(try screen.shows("Read"))
      #expect(try screen.shows("Bash"))
      try screen.clickControl(at: 0)
      #expect(try !screen.shows("Bash"))

      let running = transcriptScreen(
        ToolGroupView(entries: [
          settled[0], ToolEntry(call: Fixture.toolCall("c", status: "running"), result: nil),
        ]))
      defer { running.close() }
      #expect(try running.shows("Working with 2 tools"))
      #expect(try running.shows("Bash"))
    }

    @Test("A settled group with failures counts them")
    func groupFailures() throws {
      let screen = transcriptScreen(
        ToolGroupView(entries: [
          ToolEntry(call: Fixture.toolCall("a", isFailure: true), result: nil),
          ToolEntry(call: Fixture.toolCall("b"), result: nil),
        ]))
      defer { screen.close() }
      #expect(try screen.shows("1 failed"))
    }
  }
#endif
