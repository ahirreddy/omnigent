#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A request waiting on the reader in the table transcript's last row: where opening leaves
  /// the reader.
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

    /// The table over `state` in a window, reporting its inline cards to `surfaces`.
    private func screen(_ state: ConversationViewState, surfaces: DecisionSurfaces) async throws
      -> (TranscriptScrollDriver, TranscriptTableController)
    {
      let window = transcriptScreen(
        TableTranscriptHost(conversation: LiveConversation(state), actions: ConversationActions())
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
  }
#endif
