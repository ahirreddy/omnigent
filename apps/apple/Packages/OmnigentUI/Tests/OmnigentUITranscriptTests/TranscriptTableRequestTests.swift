#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A request waiting on the reader in the table transcript's last row: where opening leaves
  /// the reader, and how the keyboard reaches its card.
  @Suite("Transcript table requests", .serialized)
  @MainActor
  struct TranscriptTableRequestTests {
    static let width: CGFloat = 900
    static let height: CGFloat = 500

    init() {
      SystemSideEffects.reset()
    }

    /// Three turns, the last too long to fit the window, waiting on `decisions`.
    private func state(_ decisions: [DecisionCard] = []) -> ConversationViewState {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(3, startingAt: 10))
      state.decisions = decisions
      return state
    }

    private var approval: DecisionCard {
      DecisionCard(
        id: "card", carryingSessionId: TranscriptFixture.header.id, title: "Apply the change?",
        detail: "Do it", kind: .approval)
    }

    /// A form asking for one optional field, so Submit can be pressed at once.
    private var form: DecisionCard {
      DecisionCard(
        id: "card", carryingSessionId: TranscriptFixture.header.id, title: "Name the change",
        detail: "",
        kind: .form(fields: [FormField(key: "title", title: "Title", kind: .text, required: false)])
      )
    }

    /// The table over `state` in a window, reporting its inline cards to `surfaces`.
    private func screen(
      _ state: ConversationViewState, surfaces: DecisionSurfaces,
      actions: ConversationActions = ConversationActions()
    ) async throws -> (TranscriptScrollDriver, TranscriptTableController) {
      let window = transcriptScreen(
        TableTranscriptHost(conversation: LiveConversation(state), actions: actions)
          .environment(surfaces),
        width: Self.width, height: Self.height)
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      return (driver, try #require(driver.tableController))
    }

    @Test("Opening a session waiting on a request shows the request's actions, not its question")
    func opensAtThePendingRequest() async throws {
      // Without the request, the latest turn does not fit and opening frames its question.
      let (framedDriver, framed) = try await screen(state(), surfaces: DecisionSurfaces())
      framedDriver.screen.close()
      #expect(framed.readingAnchor()?.id == "u12")
      #expect(!framed.follow.follows)

      let surfaces = DecisionSurfaces()
      let (driver, controller) = try await screen(state([approval]), surfaces: surfaces)
      let window = driver.screen
      defer { window.close() }
      #expect(abs(driver.offset - driver.maximumOffset) < 1)
      #expect(controller.follow.follows)
      #expect(!controller.follow.pill.isShown)
      let approve = try window.withAccessibilityTree {
        try window.accessibilityFrame("approval-approve-card")
      }
      #expect(approve.minY >= 0 && approve.maxY <= Self.height, "Approve at \(approve)")
      #expect(surfaces.visibility.approvable == ["card"])
    }

    /// Presses Tab, or Shift-Tab, as the keyboard does; returns the view that then has it.
    private func tab(_ window: OffscreenWindow<AnyView>, backward: Bool = false) throws -> NSView? {
      try window.press(
        keyCode: 48, characters: backward ? "\u{19}" : "\t", modifiers: backward ? .shift : [])
      return window.activeWindow.firstResponder as? NSView
    }

    @Test("Tab goes through each row the table shows, on to the request card in the last one")
    func tabReachesTheRequestCard() async throws {
      var actions = ConversationActions()
      actions.respond = { _, _ in }
      let (driver, controller) = try await screen(
        state([form]), surfaces: DecisionSurfaces(), actions: actions)
      let window = driver.screen
      defer { window.close() }
      let last = controller.model.rows.count - 1
      let card = try #require(controller.realizedCell(at: last))
      let answer = try #require(controller.realizedCell(at: last - 1))
      window.activeWindow.makeFirstResponder(nil)
      var reached: [NSView] = []
      for _ in 0..<40 where !(reached.last?.isDescendant(of: card) ?? false) {
        if let view = try tab(window) { reached.append(view) }
      }
      // The answer's row has the keyboard first, then the card's field in the row under it.
      let inAnswer = reached.firstIndex { $0.isDescendant(of: answer) }
      let inCard = reached.firstIndex { $0.isDescendant(of: card) }
      let order = reached.map { String(describing: type(of: $0)) }
      if let inAnswer, let inCard {
        #expect(inAnswer < inCard, "\(order)")
      } else {
        Issue.record(
          "Tab reached the answer at \(String(describing: inAnswer)), the card at \(String(describing: inCard)): \(order)"
        )
      }
      // Shift-Tab from the field goes back up to the answer, not around the card.
      let back = try tab(window, backward: true)
      #expect(back?.isDescendant(of: answer) == true, "\(String(describing: back))")
      // Past the card's controls, Tab leaves the transcript for the window's other controls.
      var left = false
      for _ in 0..<8 where !left {
        left = try tab(window).map { !$0.isDescendant(of: controller.tableView) } ?? false
      }
      #expect(left)
    }
  }
#endif
