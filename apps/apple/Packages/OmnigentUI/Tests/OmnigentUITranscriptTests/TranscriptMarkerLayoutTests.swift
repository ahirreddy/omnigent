import Testing

@testable import OmnigentUIComponents
@testable import OmnigentUITestSupport

/// Where the web puts runtime notices, sub-agent and task markers, and the journal writes the
/// markers stand for (`renderItems.ts`, `BlockRenderer.tsx` `foldNoticeRuns`,
/// `taskActivity.ts` `repeatsTaskMarker`).
@Suite("Transcript markers in turns")
struct TranscriptMarkerLayoutTests {
  private typealias Fixture = TranscriptFixture

  private func marker(_ id: String, _ kind: ActivityKind = .subagentMarker) -> Row {
    var row = Fixture.activityRow(
      kind, id: id, title: "Started", summary: "Explore auth", status: "delegated",
      details: [DetailSection(id: "session", title: "Session", text: "child-1", isCode: true)])
    row.responseId = "subagent_\(id)"
    return row
  }

  private func segments(_ rows: [Row], isRunning: Bool = false) -> [TurnSegment] {
    TurnLayout.segments(TranscriptLayout.items(for: rows), isRunning: isRunning)
  }

  @Test("A notice starts a new turn as a user message does, and is never one")
  func noticeIsATurnBoundary() {
    let notice = Fixture.activityRow(
      .systemNotice, id: "n1", title: "Timer t1 fired", status: "timer_fired")
    let rows = [
      Fixture.user("u"), Fixture.toolCall("c1"), Fixture.answer("a1"), notice,
      Fixture.toolCall("c2"), Fixture.answer("a2"),
    ]
    let shown = segments(rows)
    #expect(shown.map(\.id) == ["u", "worked:tools:c1", "a1", "n1", "worked:tools:c2", "a2"])
    #expect(shown.filter(\.isUserMessage).map(\.id) == ["u"])
    let blocks = CLILayout.blocks(
      shown, durations: ["resp-1": 3], timestamps: [:], isRunning: false)
    // Each turn the notice ends gets its own "Worked for" line.
    #expect(blocks.filter { if case .footer = $0 { true } else { false } }.count == 2)
  }

  @Test("A marker folds with the work beside it; a run of markers joins the earlier work")
  func markersFoldWithWork() {
    let rows = [
      Fixture.user("u"), marker("m1"), Fixture.toolCall("c1"), Fixture.answer("a1"),
      marker("m2", .taskMarker), Fixture.answer("a2"),
    ]
    let shown = segments(rows)
    #expect(shown.map(\.id) == ["u", "worked:m1", "a1", "a2"])
    #expect(shown[1].items.map(\.id) == ["m1", "tools:c1", "m2"])
  }

  @Test("With no work to fold into, markers stay visible")
  func markersWithoutWorkStayVisible() {
    let shown = segments([Fixture.user("u"), marker("m1"), Fixture.answer("a1")])
    #expect(shown.map(\.id) == ["u", "m1", "a1"])
  }

  @Test("The turn's latest markers stay after its fold until committed work follows")
  func latestMarkersStayAfterTheFold() {
    let rows = [
      Fixture.user("u"), Fixture.toolCall("c1"), Fixture.answer("a1"), marker("m2"),
    ]
    #expect(segments(rows).map(\.id) == ["u", "worked:tools:c1", "a1", "m2"])
    let later = rows + [Fixture.toolCall("c2"), Fixture.answer("a2")]
    #expect(segments(later).map(\.id) == ["u", "worked:tools:c1", "a1", "worked:m2", "a2"])
  }

  @Test("An accepted journal write shows no row; a rejected one or another server's does")
  func journalWritesRepeatMarkers() {
    func write(_ name: String, output: String?, status: String = "completed") -> [Row] {
      let call = Fixture.toolCall("call-\(name)", title: name, status: status)
      guard let output else { return [call] }
      return [call, Fixture.toolResult("result-\(name)", callID: call.id, output: output)]
    }
    let accepted = write("mcp__omnigent__sys_journal_write_status", output: "{\"ok\": true}")
    let plan = write("sys_journal_write_plan", output: "Plan saved")
    let running = write("sys_journal_write_status", output: nil, status: "in_progress")
    let rejected = write("sys_journal_write_plan", output: "{\"error\": \"unknown step\"}")
    let failed = write("sys_journal_write_status", output: "Error: no plan")
    let other = write("mcp__linear__sys_journal_write_status", output: "{}")
    for rows in [accepted, plan, running] {
      #expect(TranscriptLayout.items(for: rows).isEmpty, "\(rows.map(\.id))")
    }
    for rows in [rejected, failed, other] {
      #expect(TranscriptLayout.items(for: rows).count == 1, "\(rows.map(\.id))")
    }
    #expect(JournalWrite.ownTool("mcp__omnigent__omnigent__x") == "x")
    #expect(JournalWrite.ownTool("plain_tool") == "plain_tool")
  }

  @Test("A settled thought previews its first line; one streaming or empty does not")
  func reasoningPreview() {
    let text = DetailSection(id: "summary", title: "Summary", text: "Planning the fix.\nThen.")
    let settled = Activity(
      kind: .reasoning, title: "R", summary: "Planning the fix.", details: [text])
    #expect(ReasoningText.preview(settled, isStreaming: false) == "Planning the fix.")
    #expect(ReasoningText.preview(settled, isStreaming: true) == nil)
    let markupOnly = Activity(kind: .reasoning, title: "R", summary: "", details: [text])
    #expect(ReasoningText.preview(markupOnly, isStreaming: false) == nil)
    #expect(ReasoningText.text(markupOnly) != nil)
    let empty = Activity(
      kind: .reasoning, title: "R", summary: "No public reasoning summary was provided.")
    #expect(ReasoningText.preview(empty, isStreaming: false) == nil)
    #expect(ReasoningText.text(empty) == nil)
  }
}
