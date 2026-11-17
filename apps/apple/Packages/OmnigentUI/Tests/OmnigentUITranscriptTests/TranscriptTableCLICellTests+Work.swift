#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A turn's tool work in CLI text cells: the long transcript's kinds of tool call, the reader
  /// opening and collapsing them, and the prewarm laying CLI texts out while the reader is still.
  extension TranscriptTableCLICellTests {
    /// A tool call and its result, as the long transcript records them.
    static func tool(
      _ id: String, _ name: String, command: String, output: String
    ) -> ToolEntry {
      let arguments = "{\"path\": \"Sources/File12.swift\", \"command\": \"\(command)\"}"
      return ToolEntry(
        call: TranscriptFixture.toolCall(id, title: name, summary: arguments),
        result: TranscriptFixture.toolResult("\(id)-result", callID: id, output: output))
    }

    /// A unified diff of `lines` changed lines.
    static func patch(lines: Int) -> String {
      let head = [
        "diff --git a/Sources/File12.swift b/Sources/File12.swift",
        "--- a/Sources/File12.swift", "+++ b/Sources/File12.swift", "@@ -1,8 +1,8 @@",
      ]
      let body = (0..<lines).flatMap { ["-  let old\($0) = \($0)", "+  let new\($0) = \($0 * 2)"] }
      return (head + body).joined(separator: "\n")
    }

    /// A settled turn's tool work, as the long transcript's turns have it.
    func worked(_ id: String, _ items: [TranscriptItem]) -> TranscriptTableRow {
      row(.segment(.worked(id: id, responseID: "resp-1", items: items, isLive: false)))
    }

    var workRows: [TranscriptTableRow] {
      let output = (0..<24).map { "bash line \($0): turn 12 call 0 ok" }.joined(separator: "\n")
      let reasoning = TranscriptFixture.activityRow(
        .reasoning, id: "r1", title: "Reasoning", summary: "Checking how the cache is called.")
      return [
        worked(
          "w1",
          [
            .activity(reasoning),
            .tools(
              id: "t1",
              entries: [
                Self.tool("c1", "bash", command: "bash 12", output: output),
                Self.tool(
                  "c2", "apply_patch", command: "apply_patch 12", output: Self.patch(lines: 8)),
                Self.tool("c3", "read_file", command: "read_file 12", output: output),
                Self.tool("c4", "grep", command: "grep 12", output: output),
              ]),
          ]),
        worked(
          "w2",
          [
            .tools(
              id: "t2",
              entries: [
                Self.tool("c5", "bash", command: "echo one\\necho two\\necho three", output: "one"),
                Self.tool(
                  "c6", "apply_patch", command: "apply_patch", output: Self.patch(lines: 2)),
              ])
          ]),
      ]
    }

    @Test("While the reader is still, the CLI rows around the viewport are built and measured")
    func idleMeasuring() async throws {
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(30, startingAt: 300)))
      let window = transcriptScreen(Host(conversation: conversation), width: Self.width)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let driver = TranscriptScrollDriver(screen: window)
      let table = try #require(driver.scrollView?.documentView as? NSTableView)
      let controller = try #require(table.delegate as? TranscriptTableController)
      window.run(for: TranscriptTableController.prefetchDelay)
      // Rows well inside the idle reach: its edge moves as the rows inside it are measured.
      let shown = try #require(driver.scrollView).contentView.bounds
      let near = shown.insetBy(dx: 0, dy: -shown.height * 3)
      let rows = controller.model.rows.indices.filter {
        let rect = table.rect(ofRow: $0)
        return rect.minY >= near.minY && rect.maxY <= near.maxY
      }
      let width = controller.cli.style.column(width: controller.model.width).width
      func isDone(_ index: Int) -> Bool {
        guard !controller.model.needsMeasure(at: index) else { return false }
        guard let text = controller.cliText(at: index) else { return true }
        return controller.cli.style.builtDocument(for: text.spec, width: width) != nil
      }
      // Idle passes measure the rows nearest first, each once the prewarm has laid it out.
      for _ in 0..<50 where !rows.allSatisfy(isDone) {
        window.run(for: 0.1)
      }
      for index in rows {
        #expect(isDone(index), "row \(index)")
      }
      #expect(rows.contains { controller.cliText(at: $0) != nil })
    }

    @Test("Tool work is built off the main actor too, looked up by its key")
    func workPrewarm() async throws {
      let style = style(environment())
      let column = style.column(width: Self.width)
      let context = try #require(style.prewarmContext(width: column.width))
      let palette = try #require(style.text?.palette)
      let row = try #require(workRows.last)
      let text = try #require(
        TranscriptTableCLIText.make(
          row, rendering: .styled, palette: palette, expansions: CLIWorkExpansions()))
      #expect(text.kind == .work)
      #expect(CLITextSpec(key: text.spec.key) == nil, "tool work's key doesn't spell it out")
      let prewarm = CLITextPrewarm(limit: 8)
      prewarm.note(context)
      prewarm.prioritize([text.spec], at: [0])
      let deadline = Date().addingTimeInterval(5)
      while style.builtDocument(for: text.spec, width: column.width) == nil, Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(style.builtDocument(for: text.spec, width: column.width) != nil)
    }

    @Test("Tool work's lines carry SwiftUI's identifiers, and '… +N lines' is a button")
    func workAccessibility() throws {
      let style = style(environment())
      let cell = TranscriptTableCLICell(style: style)
      cell.show(try #require(workRows.first), version: 0, width: Self.width)
      func regions() -> [TranscriptTableCLIRegionElement] {
        (cell.accessibilityChildren() ?? []).compactMap { $0 as? TranscriptTableCLIRegionElement }
      }
      let lines = regions().filter { $0.accessibilityRole() == .group }
      // A call's line, an explored line and reasoning, as CLIToolLine, CLIExploredRow and
      // CLIActivityLine name them.
      #expect(
        Set(lines.map { $0.accessibilityIdentifier() })
          == ["reasoning-r1", "tool-c1", "tool-c2", "tool-c3", "tool-c4"])
      #expect(
        lines.first { $0.accessibilityIdentifier() == "tool-c1" }?.accessibilityLabel()
          == "Ran bash 12")
      let more = try #require(regions().first { $0.accessibilityRole() == .button })
      #expect(more.accessibilityLabel() == "\u{2026} +21 lines")
      let closed = cell.idealHeight
      #expect(more.accessibilityPerformPress())
      #expect(cell.idealHeight > closed)
      // Opened, the output has no "… +N lines" of its own.
      #expect(!regions().contains { $0.accessibilityLabel() == "\u{2026} +21 lines" })
    }

    @Test("Opening a tool line's output or collapsing the group lays the cell out again")
    func workExpansions() throws {
      let environment = environment()
      let style = style(environment)
      let expansions = CLIWorkExpansions()
      let row = try #require(workRows.first)
      let cell = TranscriptTableCLICell(style: style, expansions: expansions)
      cell.show(row, version: 0, width: Self.width)
      let closed = cell.idealHeight
      var changed = false
      cell.idealSizeChanged = { _ in changed = true }
      // "… +21 lines" under the command opens its output, as Show output does.
      cell.toggle("c1")
      #expect(changed)
      #expect(cell.idealHeight > closed)
      cell.toggle("c1")
      #expect(cell.idealHeight == closed)
      cell.toggle("w1", collapsing: true)
      #expect(cell.idealHeight < closed)
      // Collapsed, the group is its one summary line.
      let collapsed = try #require(cell.document)
      #expect(collapsed.text.text.string.hasSuffix("\u{2026}"))
    }
  }
#endif
