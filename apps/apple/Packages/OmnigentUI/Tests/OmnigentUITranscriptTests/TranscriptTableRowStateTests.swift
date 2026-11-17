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

    private func screen(_ conversation: LiveConversation) async throws -> (
      TranscriptScrollDriver, TranscriptTableController
    ) {
      let window = transcriptScreen(
        TableTranscriptHost(conversation: conversation, actions: ConversationActions()),
        width: 900, height: 500)
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      return (driver, try #require(driver.tableController))
    }

    /// The Worked fold row of `turn` and the id of its first item.
    private func fold(of turn: Int, in controller: TranscriptTableController) throws -> (
      row: String, item: String
    ) {
      for row in controller.model.rows {
        guard case .segment(let entry) = row.content,
          case .worked(_, _, let items, _) = entry.segment,
          let first = items.first, first.id.contains("c\(turn)")
        else { continue }
        return (row.id, first.id)
      }
      throw OffscreenWindowError.notFound("the Worked fold of turn \(turn)")
    }

    @Test("A fold opened stays open when its cell goes to another row and the row comes back")
    func foldOutlivesItsCell() async throws {
      let (driver, controller) = try await screen(session(turns: 30))
      let window = driver.screen
      defer { window.close() }
      let fold = try fold(of: 29, in: controller)
      let index = try #require(controller.model.index(of: fold.row))
      let closed = controller.model.height(at: index)
      // The fold's title leads its row, in the transcript's column.
      let row = controller.tableView.convert(
        controller.tableView.rect(ofRow: index), to: window.host)
      try window.click(CGPoint(x: row.minX + 100, y: row.minY + 20))
      try await letTasksRun(window)
      #expect(controller.disclosures.choice("worked-\(fold.item)").isExpanded == true)
      // Open, it shows its tool's row under its title, and the table gives it the height.
      let open = controller.model.height(at: index)
      #expect(open > closed + 20, "\(closed) -> \(open)")
      let opened = try #require(controller.realizedCell(at: index))

      // Keep no cell for rows that leave: the fold's goes to another row.
      controller.pool.parkedLimit = 0
      controller.pool.spareLimit = 1
      driver.move(to: controller.minimumOffset)
      window.run(for: 0.2)
      controller.show(fold.row, at: .top)
      try await letTasksRun(window)
      let shown = try #require(controller.realizedCell(at: index))
      #expect(shown !== opened)
      #expect(abs(shown.idealHeight - open) < 1, "\(shown.idealHeight) for \(open)")
      #expect(abs(controller.model.height(at: index) - open) < 1)
    }

    @Test("A request card in the last row tells the conversation whether it is on screen")
    func inlineCardReportsItsPlace() async throws {
      let card = DecisionCard(
        id: "card", carryingSessionId: TranscriptFixture.header.id, title: "Approval requested",
        detail: "Do it", kind: .approval)
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(6))
      state.decisions = [card]
      let conversation = LiveConversation(state)
      let surfaces = DecisionSurfaces()
      let window = transcriptScreen(
        TableTranscriptHost(conversation: conversation, actions: ConversationActions())
          .environment(surfaces),
        width: 900, height: 500)
      defer { window.close() }
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      let controller = try #require(driver.tableController)
      controller.jumpToLatest()
      try await letTasksRun(window)
      #expect(
        surfaces.visibility.onScreen == ["card"],
        "footer viewport \(String(describing: controller.tableViewport.footer))")
      #expect(surfaces.visibility.approvable == ["card"])

      // Scrolled away above, the card is off screen and the dock answers it.
      driver.move(to: controller.minimumOffset)
      try await letTasksRun(window)
      #expect(surfaces.visibility.onScreen.isEmpty)
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

    /// The strings an assistive client reads under `element`, in reading order.
    private static func read(_ element: Any) -> [String] {
      guard let element = element as? NSObject else { return [] }
      var read: [String] = []
      for name in ["accessibilityLabel", "accessibilityValue"]
      where element.responds(to: NSSelectorFromString(name)) {
        if let text = element.value(forKey: name) as? String, !text.isEmpty { read.append(text) }
      }
      guard element.responds(to: NSSelectorFromString("accessibilityChildren")) else { return read }
      for child in element.value(forKey: "accessibilityChildren") as? [Any] ?? [] {
        read += Self.read(child)
      }
      return read
    }

    @Test("The transcript is a labelled scroll area whose rows are read in order")
    func rowsAsElements() async throws {
      let (driver, controller) = try await screen(session(turns: 4))
      let window = driver.screen
      defer { window.close() }
      let scrollView = try #require(driver.scrollView)
      #expect(scrollView.accessibilityIdentifier() == "transcript-\(TranscriptFixture.header.id)")
      #expect(scrollView.accessibilityLabel() == "Transcript")
      #expect(controller.tableView.accessibilityRole() == .group)
      try window.withAccessibilityTree {
        var read: [String] = []
        for _ in 0..<2 {
          read = Self.read(window.window)
          window.settle(0.3)
        }
        let question = read.firstIndex { $0.contains("Question 3") }
        let answer = read.firstIndex { $0.contains("Line 0 of answer 3") }
        let cells = controller.accessibilityRows().compactMap { $0 as? NSView }
        let shapes = cells.map { cell in
          let children = cell.accessibilityChildren()?.count ?? -1
          let role = cell.accessibilityRole()?.rawValue ?? "none"
          return "\(role) \(cell.isAccessibilityElement()) \(children)/\(cell.subviews.count)"
        }
        #expect(question != nil, "\(shapes): \(read.prefix(12))")
        #expect(answer != nil, "\(read.prefix(12))")
        if let question, let answer { #expect(question < answer) }
      }
    }

    @Test("An assistive client reads every row, those far above the window too")
    func assistiveClientReadsEveryRow() async throws {
      let (driver, controller) = try await screen(session(turns: 30))
      let window = driver.screen
      defer { window.close() }
      try window.withAccessibilityTree {
        var read: [String] = []
        for _ in 0..<2 {
          read = Self.read(window.window)
          window.settle(0.3)
        }
        #expect(controller.isReadByAssistiveClient)
        #expect(read.contains { $0.contains("Line 2 of answer 0") })
      }
      #expect(AssistiveClientNotice.isWritten)
    }
  }
#endif
