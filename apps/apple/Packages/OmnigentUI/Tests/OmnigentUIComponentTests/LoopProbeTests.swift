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

    @Test func changesWithinASecondAreReportedOnce() {
      probing { lines in
        let start = Date()
        for index in 0..<(LoopProbe.limit * 2) {
          LoopProbe.record("dock", at: start.addingTimeInterval(Double(index) / 1000), "state")
        }
        #expect(lines.all == ["LOOP dock changed 30 times within a second: state"])
      }
    }

    @Test func changesSpreadOverSecondsAreNot() {
      probing { lines in
        let start = Date()
        for index in 0..<(LoopProbe.limit * 3) {
          LoopProbe.record("dock", at: start.addingTimeInterval(Double(index) / 20), "state")
        }
        #expect(lines.all.isEmpty)
      }
    }

    @Test func aLoopThatNeverEndsIsReportedAFewTimes() {
      probing { lines in
        let start = Date()
        for second in 0..<20 {
          for index in 0..<LoopProbe.limit {
            let time = start.addingTimeInterval(Double(second) * 1.5 + Double(index) / 1000)
            LoopProbe.record("dock", at: time, "state")
          }
        }
        #expect(lines.all.count == LoopProbe.reportsPerName)
      }
    }
  }
#endif
