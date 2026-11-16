#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The transcript's width, which a test changes as a window resize does.
  @MainActor
  @Observable
  private final class TranscriptColumn {
    var width: CGFloat

    init(width: CGFloat) {
      self.width = width
    }
  }

  private struct ResizingTranscriptHost: View {
    let conversation: LiveConversation
    let column: TranscriptColumn

    var body: some View {
      LiveTranscriptHost(conversation: conversation, actions: ConversationActions())
        .frame(width: column.width)
    }
  }

  @Suite("Transcript resizing", .serialized)
  @MainActor
  struct TranscriptResizingTests {
    private static let wide: CGFloat = 900
    private static let narrow: CGFloat = 420

    private func longAnswers() -> LiveConversation {
      let paragraph = String(repeating: "A reasonably long line of the answer. ", count: 40)
      let rows = (0..<8).flatMap { index in
        [
          TranscriptFixture.user("u\(index)", "Question \(index)"),
          TranscriptFixture.answer("a\(index)", paragraph, responseID: "r\(index)"),
        ]
      }
      return LiveConversation(ConversationViewState(header: TranscriptFixture.header, rows: rows))
    }

    @Test("A narrower window keeps an earlier reader in the same place in the conversation")
    func readerKeepsPlace() async throws {
      let column = TranscriptColumn(width: Self.wide)
      let window = transcriptScreen(
        ResizingTranscriptHost(conversation: longAnswers(), column: column), width: Self.wide,
        height: 500)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      let viewport = TranscriptScrollDriver(screen: window)
      // Going to an earlier question is what stops following here; a scroll has no phases offscreen.
      let opened = viewport.offset
      #expect(
        try await window.waitUntil {
          try pressMessageKey(.previous, on: window)
          return viewport.offset < opened
        })
      for _ in 0..<2 {
        try pressMessageKey(.previous, on: window)
        try await letTasksRun(window, milliseconds: 100)
      }
      let before = viewport.fractionRead

      column.width = Self.narrow
      try await letTasksRun(window, milliseconds: 300)
      // The turns are all alike, so the same place is the same share of the conversation.
      #expect(abs(viewport.fractionRead - before) < 0.1)
    }

    @Test("A narrower window keeps a reader at the latest message at the bottom")
    func followerStaysAtBottom() async throws {
      let column = TranscriptColumn(width: Self.wide)
      let window = transcriptScreen(
        ResizingTranscriptHost(conversation: longAnswers(), column: column), width: Self.wide,
        height: 500)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 200)
      column.width = Self.narrow
      // Measuring moves the scroll view as a reader would, so only once the rows are back.
      let settle = Int(TranscriptScrollState.restoreWindow * 2_000)
      try await letTasksRun(window, milliseconds: settle)
      let distance = TranscriptScrollDriver(screen: window).distanceToEnd()
      // The bottom row rests the rows' padding short of the content's edge.
      #expect(distance <= Theme.Spacing.extraLarge + 1, "\(distance) points from the end")
    }
  }
#endif
