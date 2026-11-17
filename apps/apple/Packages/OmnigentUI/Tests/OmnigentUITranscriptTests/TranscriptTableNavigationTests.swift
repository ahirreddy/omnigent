#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The table transcript's keys and jumps: previous and next message, the keys that scroll it,
  /// Jump to top with its paging, and jumps that ease to where they go.
  @Suite("Transcript table navigation", .serialized)
  @MainActor
  struct TranscriptTableNavigationTests {
    static let width: CGFloat = 900
    static let height: CGFloat = 500
    let log = HostLog()

    init() {
      SystemSideEffects.reset()
    }

    private func session(turns: Int = 8, hasMore: Bool = false) -> LiveConversation {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: TranscriptFixture.turns(turns, startingAt: 10))
      state.hasMoreHistory = hasMore
      return LiveConversation(state)
    }

    private func screen(
      _ conversation: LiveConversation, actions: ConversationActions = ConversationActions()
    ) async throws -> (TranscriptScrollDriver, TranscriptTableController) {
      let window = transcriptScreen(
        TableTranscriptHost(conversation: conversation, actions: actions), width: Self.width,
        height: Self.height)
      try await letOpeningEnd(window)
      let driver = TranscriptScrollDriver(screen: window)
      return (driver, try #require(driver.tableController))
    }

    @Test("With motion on a jump eases to where it goes, and the reader's scroll stops it")
    func animatedJumps() async throws {
      Theme.Motion.isEnabled = true
      defer { Theme.Motion.isEnabled = false }
      let (driver, controller) = try await screen(session())
      let window = driver.screen
      defer { window.close() }
      #expect(controller.animatesJumps)
      let start = driver.offset
      controller.show("u12", at: .top, animated: true)
      #expect(controller.activeJump != nil)
      #expect(abs(driver.offset - start) < 1, "a jump starts where the reader is")
      let target = try #require(controller.model.index(of: "u12"))
      #expect(
        await window.waitUntil {
          controller.activeJump == nil
            && abs(driver.offset - controller.tableView.rect(ofRow: target).minY) < 1
        })

      controller.jumpToLatest(animated: true)
      window.run(for: TranscriptTableJump.duration / 3)
      let midway = driver.offset
      #expect(midway > controller.tableView.rect(ofRow: target).minY + 1)
      #expect(midway < driver.maximumOffset - 1)
      controller.readerScrolled()
      #expect(controller.activeJump == nil)
      window.run(for: TranscriptTableJump.duration)
      #expect(abs(driver.offset - midway) < 1)
    }
  }
#endif
