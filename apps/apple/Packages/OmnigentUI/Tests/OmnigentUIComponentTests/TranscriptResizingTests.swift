#if os(macOS)
  import AppKit
  import Observation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

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
      #expect(
        try await waitUntil(window) { navigatorButtons(on: window, width: Self.wide).count == 2 })
      let previous = try #require(navigatorButtons(on: window, width: Self.wide).first)
      for _ in 0..<3 {
        try window.click(CGPoint(x: previous.midX, y: previous.midY))
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
      let viewport = TranscriptScrollDriver(screen: window)
      #expect(try await waitUntil(window) { viewport.distanceToEnd() < 2 })
    }
  }
#endif
