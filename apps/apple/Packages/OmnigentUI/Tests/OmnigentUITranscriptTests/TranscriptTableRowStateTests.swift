#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What the table transcript's rows keep across reused cells, and what an assistive client
  /// reads of them.
  @Suite("Transcript table rows", .serialized)
  @MainActor
  struct TranscriptTableRowStateTests {
    init() {
      SystemSideEffects.reset()
    }

    /// Turns of a question, a tool call and an answer: settled, each folds its tool work.
    private func session(turns: Int) -> LiveConversation {
      let rows = (0..<turns).flatMap { turn -> [Row] in
        [
          TranscriptFixture.user("u\(turn)", "Question \(turn)"),
          TranscriptFixture.toolCall("c\(turn)", summary: "ls step-\(turn)"),
          TranscriptFixture.toolResult("o\(turn)", callID: "c\(turn)"),
          TranscriptFixture.answer(
            "a\(turn)", (0..<6).map { "Line \($0) of answer \(turn)" }.joined(separator: "\n\n"),
            responseID: "r\(turn)"),
        ]
      }
      return LiveConversation(ConversationViewState(header: TranscriptFixture.header, rows: rows))
    }

    @Test("Text selected in a row offers Reply, and a scroll of the table hides it")
    func selectionPopupHidesOnScroll() async throws {
      let log = HostLog()
      var actions = ConversationActions()
      actions.replyWithSelection = { log.add($0) }
      let window = transcriptScreen(
        TableTranscriptHost(conversation: session(turns: 6), actions: actions), width: 900,
        height: 500)
      defer { window.close() }
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      let controller = try #require(driver.tableController)
      let index = try #require(controller.model.index(of: "a4"))
      controller.show("a4", at: .top)
      try await letTasksRun(window)
      let row = controller.tableView.convert(
        controller.tableView.rect(ofRow: index), to: window.host)
      // A word of the answer's first line, which leads its row in the column.
      try window.click(CGPoint(x: row.minX + 100, y: row.minY + 10), clickCount: 2)
      try await announceSelection(window)
      #expect(try window.shows("Reply"))
      driver.move(to: driver.offset - 80)
      try await letTasksRun(window)
      #expect(try !window.shows("Reply"))
    }

  }
#endif
