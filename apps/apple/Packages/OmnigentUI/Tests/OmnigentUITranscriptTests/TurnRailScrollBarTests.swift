#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Counts frame changes posted by a set of views, from any thread.
  private final class FrameChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var tokens: [any NSObjectProtocol] = []

    init(_ views: [NSView]) {
      for view in views {
        view.postsFrameChangedNotifications = true
        tokens.append(
          NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: nil
          ) { [weak self] _ in self?.add() })
      }
    }

    var total: Int { lock.withLock { count } }

    private func add() {
      lock.withLock { count += 1 }
    }

    func stop() {
      tokens.forEach(NotificationCenter.default.removeObserver)
    }
  }

  /// A long transcript's turn rail where scroll bars take room beside the content, as with a
  /// mouse or "Show scroll bars: Always". The bars are chosen before the process makes its first
  /// scroll view, so the scenario runs in a process of its own; its exit code names a failure.
  @Suite("Turn rail with scroll bars that take room", .serialized)
  @MainActor
  struct TurnRailScrollBarTests {
    /// Enough turns that the rail scrolls: more than its height shows.
    private static let turns = 60
    /// Frame changes a resting window may still make while it is watched.
    private static let restingChanges = 2

    private enum Failure: Int32 {
      case overlayScrollBars = 81
      case noRail = 82
      case railFits = 83
      case layoutChurns = 84
      case ticksSqueezed = 85
    }

    @Test("A long transcript's turn rail comes to rest and keeps its width")
    func railRests() async {
      await #expect(processExitsWith: .success) {
        try await TurnRailScrollBarTests.openLongTranscript()
      }
    }

    private nonisolated static func end(_ failure: Failure, _ reason: String) -> Never {
      FileHandle.standardError.write(Data("turn rail: \(reason)\n".utf8))
      _exit(failure.rawValue)
    }

    private static func openLongTranscript() async throws {
      let defaults = UserDefaults.standard
      var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
      arguments["AppleShowScrollBars"] = "Always"
      defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
      guard NSScroller.preferredScrollerStyle == .legacy else {
        end(.overlayScrollBars, "scroll bars still overlay the content")
      }
      guard CGFloat(turns) * TurnRail.pitch + 2 * TurnRail.fade > TurnRail.maxHeight else {
        end(.railFits, "\(turns) turns fit the rail without scrolling")
      }

      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptFixture.turns(turns)))
      let window = transcriptScreen(
        DockedTranscriptHost(
          conversation: conversation, pane: TranscriptPane(width: 900, dock: 68)),
        width: 900, height: 600)
      defer { window.close() }
      try await letOpeningEnd(window)

      // The narrowest scroll view, not one exactly the gutter's width: a rail that never rests
      // does not keep one frame for long.
      let scrollViews = window.allViews.compactMap { $0 as? NSScrollView }
      guard let rail = scrollViews.min(by: { $0.frame.width < $1.frame.width }),
        rail.frame.width < TurnRail.width * 2
      else {
        end(.noRail, "no rail among \(scrollViews.map(\.frame.size))")
      }

      let changes = FrameChanges(
        scrollViews.flatMap { [$0.contentView, $0.documentView].compactMap { $0 } })
      MainLoop.run(for: 0.5)
      changes.stop()
      guard changes.total <= restingChanges else {
        end(.layoutChurns, "scroll views changed frame \(changes.total) times in half a second")
      }
      guard rail.contentView.frame.width == TurnRail.width else {
        end(.ticksSqueezed, "the ticks have \(rail.contentView.frame.width) of its width")
      }
    }
  }
#endif
