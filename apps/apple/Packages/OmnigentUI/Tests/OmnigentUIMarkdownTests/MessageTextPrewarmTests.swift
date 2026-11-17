#if os(macOS)
  import AppKit
  import SwiftUI
  import Synchronization
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// How many texts a queue's workers lay out at once, at most, and which they laid out.
  nonisolated private final class Tally: Sendable {
    private struct Counts {
      var running = 0
      var most = 0
      var done: [String] = []
    }

    private let counts = Mutex(Counts())

    var most: Int { counts.withLock { $0.most } }
    var done: [String] { counts.withLock { $0.done } }

    func run(_ text: String) {
      counts.withLock {
        $0.running += 1
        $0.most = max($0.most, $0.running)
      }
      Thread.sleep(forTimeInterval: 0.05)
      counts.withLock {
        $0.running -= 1
        $0.done.append(text)
      }
    }
  }

  /// Answers laid out off the main actor ahead of their rows.
  @MainActor
  @Suite("TextKit answers laid out ahead", .serialized)
  struct MessageTextPrewarmTests {
    private static let answer = """
      ## Step 3

      A paragraph with `code` and [a link](https://example.com/a).

      ```swift
      let a = 1
      let b = 2
      ```
      """

    /// The document `prewarm` prepared for all of `text`, waited for.
    private func prepared(_ text: String, in prewarm: MessageTextPrewarm) async throws
      -> MessageTextDocument?
    {
      let key = MessageTextDocumentKey(
        text: text, piece: 0, style: MessageTextFixture.style, linked: [])
      for _ in 0..<400 {
        if let document = prewarm.takeDocument(for: key) { return document }
        try await Task.sleep(for: .milliseconds(10))
      }
      return nil
    }

    @Test("An answer offered before the width is known lays out once a row shows the width")
    func laysOutAhead() async throws {
      let prewarm = MessageTextPrewarm(limit: 8)
      prewarm.offer(Self.answer)
      let palette = MessageTextPalette(MessageTextFixture.style)
      #expect(try await prepared(Self.answer, in: MessageTextPrewarm(limit: 8)) == nil)
      prewarm.note(palette: palette, width: 500)
      let document = try #require(try await prepared(Self.answer, in: prewarm))
      let built = MessageTextFixture.document(Self.answer)
      #expect(document.text.string == built.text.string)
      let view = MessageTextContentView(document: document)
      #expect(document.takePreparedLayout() == nil, "the view took the layout")
      let layout = try #require(view.textView.textLayoutManager)
      var laidOut = 0
      var total = 0
      let start = layout.documentRange.location
      _ = layout.enumerateTextLayoutFragments(from: start, options: []) { fragment in
        total += 1
        if fragment.state == .layoutAvailable { laidOut += 1 }
        return true
      }
      #expect(total > 3 && laidOut == total, "laid out off the main actor: \(laidOut)/\(total)")
      let size = view.fittingSize(for: 500, fillsWidth: true)
      let fresh = MessageTextContentView(document: built).fittingSize(for: 500, fillsWidth: true)
      #expect(size == fresh)
    }

    @Test("An answer that cites workspace paths waits for its row, which links them")
    func citedPathsWait() async throws {
      let prewarm = MessageTextPrewarm(limit: 8)
      let text = "See `Sources/App/main.swift` for the entry point."
      prewarm.note(palette: MessageTextPalette(MessageTextFixture.style), width: 500)
      prewarm.offer(text)
      prewarm.offer(Self.answer)
      #expect(try await prepared(Self.answer, in: prewarm) != nil)
      #expect(try await prepared(text, in: prewarm) == nil)
    }

    @Test("Several workers lay texts out at once, and a text asked for once done isn't again")
    func workers() async throws {
      let tally = Tally()
      let queue = MessageTextPrewarmQueue<Int>(limit: 8, workers: 3) { text, _, _ in
        tally.run(text)
      }
      queue.setContext(1) { _ in false }
      queue.prioritize(["a", "b", "c", "d"], at: [0, 1, 2, 3])
      for _ in 0..<200 where tally.done.count < 4 {
        try await Task.sleep(for: .milliseconds(10))
      }
      #expect(tally.done.count == 4)
      #expect(tally.most > 1, "laid out side by side")
      queue.prioritize(["a"], at: [0])
      queue.offer("b")
      #expect(queue.pendingTexts.isEmpty, "both are laid out in this context")
      try await Task.sleep(for: .milliseconds(100))
      #expect(tally.done.count == 4)
    }

    @Test("The prewarm is on unless a launch argument or default turns it off")
    func switchedOff() {
      let suite = "message-text-prewarm-\(UUID().uuidString)"
      let defaults = UserDefaults(suiteName: suite) ?? .standard
      defaults.removePersistentDomain(forName: suite)
      #expect(MessageTextPrewarm.enabled(in: defaults))
      defaults.set("NO", forKey: "omnigent:message-text-prewarm")
      #expect(!MessageTextPrewarm.enabled(in: defaults))
      defaults.set(true, forKey: "omnigent:message-text-prewarm")
      #expect(MessageTextPrewarm.enabled(in: defaults))
      defaults.removePersistentDomain(forName: suite)
    }

    @Test("The builder's metrics are the design system's")
    func metrics() {
      #expect(MessageTextMetrics.controlTarget == Theme.Control.target)
      #expect(MessageTextMetrics.extraSmall == Theme.Spacing.extraSmall)
      #expect(MessageTextMetrics.small == Theme.Spacing.small)
      #expect(MessageTextMetrics.medium == Theme.Spacing.medium)
      #expect(MessageTextMetrics.large == Theme.Spacing.large)
      #expect(MessageTextMetrics.extraLarge == Theme.Spacing.extraLarge)
      #expect(MessageTextMetrics.tableRowPadding == MarkdownTableView.rowPadding)
    }
  }
#endif
