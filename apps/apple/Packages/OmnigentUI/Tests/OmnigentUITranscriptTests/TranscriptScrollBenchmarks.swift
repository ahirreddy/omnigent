#if os(macOS)
  import AppKit
  import Darwin
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// Main-thread time of scroll steps over a long, seeded-like conversation, offscreen. Run with
  /// `OMNIGENT_BENCH=1 swift test --package-path apps/apple/Packages/OmnigentUI --filter
  /// TranscriptScrollBenchmarks`; each prints its numbers.
  @Suite("Transcript scroll benchmarks", .serialized)
  @MainActor
  struct TranscriptScrollBenchmarks {
    private static let turns = 150
    private static let width: CGFloat = 1200
    private static let height: CGFloat = 800
    private static let step: CGFloat = 60

    private func open() async throws -> (OffscreenWindow<AnyView>, NSScrollView) {
      Theme.Timing.scale = 0.1
      defer { Theme.Timing.scale = 1 }
      let conversation = LiveConversation(
        ConversationViewState(
          header: TranscriptFixture.header, rows: TranscriptBenchmarks.rows(turns: Self.turns)))
      let window = transcriptScreen(
        DockedTranscriptHost(
          conversation: conversation, pane: TranscriptPane(width: Self.width, dock: 68)),
        width: Self.width, height: Self.height)
      window.settle(0.5)
      try await letOpeningEnd(window)
      let scrollView = try #require(TranscriptScrollDriver(screen: window).scrollView)
      return (window, scrollView)
    }

    /// Moves the clip view by `step`, then runs a frame of the main run loop, as a scroll event
    /// a frame does.
    private func move(_ scrollView: NSScrollView, by step: CGFloat) {
      let clip = scrollView.contentView
      clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + step))
      scrollView.reflectScrolledClipView(clip)
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0 / 60))
    }

    /// The main thread's CPU milliseconds for each of `steps` moves, with the main actor's
    /// tasks each move started.
    private func timeSteps(_ scrollView: NSScrollView, by step: CGFloat, steps: Int) async
      -> [Double]
    {
      var times: [Double] = []
      for _ in 0..<steps {
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        move(scrollView, by: step)
        await Task.yield()
        times.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6)
      }
      return times
    }

    private func summary(_ name: String, _ times: [Double]) {
      let sorted = times.sorted()
      let median = sorted[sorted.count / 2]
      let slowTenth = sorted[sorted.count * 9 / 10]
      let format = { (value: Double) in value.formatted(.number.precision(.fractionLength(2))) }
      print(
        "BENCH \(name): \(times.count) steps, median \(format(median)) ms, slowest tenth "
          + "\(format(slowTenth)) ms, max \(format(sorted.last ?? 0)) ms, total "
          + "\(format(times.reduce(0, +))) ms; first three "
          + times.prefix(3).map(format).joined(separator: ", "))
    }

    @Test(
      "benchmark: scroll steps over built rows, and off the bottom",
      .enabled(if: TranscriptBenchmarks.isEnabled))
    func scrollSteps() async throws {
      for round in 1...3 {
        let (window, scrollView) = try await open()
        defer { window.close() }
        // A gesture that ends at the bottom follows the newest row again.
        window.liveScroll(scrollView, began: true)
        for _ in 0..<3 {
          let maximum =
            (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height
          scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximum))
          scrollView.reflectScrolledClipView(scrollView.contentView)
          window.settle()
        }
        window.liveScroll(scrollView, began: false)

        window.liveScroll(scrollView, began: true)
        let leaving = await timeSteps(scrollView, by: -Self.step, steps: 20)
        summary("round \(round) off the bottom", leaving)
        _ = await timeSteps(scrollView, by: -Self.step, steps: 40)
        _ = await timeSteps(scrollView, by: Self.step, steps: 40)
        let upward = await timeSteps(scrollView, by: -Self.step, steps: 40)
        let downward = await timeSteps(scrollView, by: Self.step, steps: 40)
        summary("round \(round) over built rows", upward + downward)
        window.liveScroll(scrollView, began: false)
      }
    }
  }
#endif
