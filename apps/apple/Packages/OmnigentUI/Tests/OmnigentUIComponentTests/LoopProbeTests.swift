#if DEBUG
  import Foundation
  import Testing

  @testable import OmnigentUIComponents

  /// The probe reports a state that changes many times a second, and only that.
  @MainActor
  @Suite("Loop probe", .serialized)
  struct LoopProbeTests {
    private final class Lines {
      var all: [String] = []
    }

    private func probing(_ body: (Lines) -> Void) {
      let lines = Lines()
      LoopProbe.reset()
      LoopProbe.sink = { lines.all.append($0) }
      defer {
        LoopProbe.sink = nil
        LoopProbe.reset()
      }
      body(lines)
    }

    /// Changes `perSecond` times a second for `seconds` seconds from `start`.
    private func change(perSecond: Int, seconds: Int, from start: Date = Date()) {
      for second in 0..<seconds {
        for index in 0..<perSecond {
          let offset = Double(second) + Double(index) / Double(perSecond) * 0.9
          LoopProbe.record("dock", at: start.addingTimeInterval(offset), "\(index % 2)")
        }
      }
    }

    @Test func aBusyStateForSecondsIsReported() {
      probing { lines in
        change(perSecond: LoopProbe.limit * 2, seconds: LoopProbe.busySeconds)
        #expect(
          lines.all == ["LOOP dock changed 30 times a second for 3 seconds: 0 | 1 | 0 | 1 | 0 | 1"])
      }
    }

    /// A resize changes the dock every frame while the window moves.
    @Test func aBusySecondOrTwoIsNot() {
      probing { lines in
        change(perSecond: LoopProbe.limit * 2, seconds: LoopProbe.busySeconds - 1)
        #expect(lines.all.isEmpty)
      }
    }

    @Test func changesSpreadOverSecondsAreNot() {
      probing { lines in
        change(perSecond: LoopProbe.limit / 2, seconds: 20)
        #expect(lines.all.isEmpty)
      }
    }

    /// The host resizing a window itself changes layout every frame while it does.
    @Test func aBusyStateWhileQuietIsNot() {
      probing { lines in
        let start = Date()
        LoopProbe.quiet(for: Double(LoopProbe.busySeconds + 1), from: start)
        change(perSecond: LoopProbe.limit * 2, seconds: LoopProbe.busySeconds + 1, from: start)
        #expect(lines.all.isEmpty)
      }
    }

    @Test func aLoopThatOutlastsTheQuietIsReported() {
      probing { lines in
        let start = Date()
        LoopProbe.quiet(for: 2, from: start)
        change(perSecond: LoopProbe.limit * 2, seconds: 2 + LoopProbe.busySeconds, from: start)
        #expect(lines.all.count == 1)
      }
    }

    @Test func aLoopThatNeverEndsIsReportedAFewTimes() {
      probing { lines in
        change(perSecond: LoopProbe.limit, seconds: 40)
        #expect(lines.all.count == LoopProbe.reportsPerName)
      }
    }
  }
#endif
