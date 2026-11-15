#if os(macOS)
  import Foundation
  import OmnigentViewTestingBootstrap
  import os

  /// Where a test process's waits spend their time. With `OMNIGENT_WAIT_STATS=1` each wait's
  /// total, count and how many took their whole limit print to standard error as it exits.
  enum WaitStats {
    struct Total: Equatable {
      var seconds: TimeInterval = 0
      var count = 0
      var reachedLimit = 0
    }

    /// Whether waits take their whole limit, as they did before they ended at rest.
    static let fixedWaits = ProcessInfo.processInfo.environment["OMNIGENT_FIXED_WAITS"] == "1"
    static let isRecording = ProcessInfo.processInfo.environment["OMNIGENT_WAIT_STATS"] == "1"
    private static let totals = OSAllocatedUnfairLock(initialState: [String: Total]())
    private static let printer = OSAllocatedUnfairLock(initialState: false)

    /// Adds one wait to its total.
    /// - Parameters:
    ///   - name: The kind of wait.
    ///   - start: When it began, as an absolute time.
    ///   - reachedLimit: Whether it took its whole limit.
    static func record(_ name: String, since start: CFAbsoluteTime, reachedLimit: Bool) {
      guard isRecording else { return }
      let seconds = CFAbsoluteTimeGetCurrent() - start
      add(name, seconds: seconds, reachedLimit: reachedLimit)
    }

    static func add(_ name: String, seconds: TimeInterval, reachedLimit: Bool) {
      installPrinter()
      totals.withLock { totals in
        totals[name, default: Total()].seconds += seconds
        totals[name, default: Total()].count += 1
        if reachedLimit { totals[name, default: Total()].reachedLimit += 1 }
      }
    }

    /// Times `body` as one wait of its own, for a helper made of several.
    static func measure<Result>(_ name: String, _ body: () throws -> Result) rethrows -> Result {
      guard isRecording else { return try body() }
      let start = CFAbsoluteTimeGetCurrent()
      defer { add(name, seconds: CFAbsoluteTimeGetCurrent() - start, reachedLimit: false) }
      return try body()
    }

    /// The totals as lines, longest first.
    static func report() -> String {
      let sorted = totals.withLock { $0 }.sorted { $0.value.seconds > $1.value.seconds }
      return sorted.map { entry in
        let total = entry.value
        let seconds = total.seconds.formatted(.number.precision(.fractionLength(2)))
        return "wait-stats \(entry.key): \(seconds)s, \(total.count) calls, "
          + "\(total.reachedLimit) at limit"
      }.joined(separator: "\n")
    }

    private static func installPrinter() {
      let isFirst = printer.withLock { installed in
        defer { installed = true }
        return !installed
      }
      guard isFirst else { return }
      atexit(printWaitStats)
    }
  }

  /// Prints the totals as the process exits.
  private func printWaitStats() {
    FileHandle.standardError.write(Data((WaitStats.report() + "\n").utf8))
  }

  /// When the process's sleeping tasks wake: the Swift runtime tells the test bundle's loader
  /// each `Task.sleep`'s end.
  enum SleepTracker {
    /// Whether some `Task.sleep` ends from now until `deadline`.
    /// - Parameter deadline: An absolute time, as `CFAbsoluteTimeGetCurrent()` gives.
    /// - Returns: Whether one does.
    static func hasSleep(endingBefore deadline: CFAbsoluteTime) -> Bool {
      let now = omnigent_view_testing_now_ns()
      let remaining = deadline - CFAbsoluteTimeGetCurrent()
      guard remaining > 0 else { return false }
      return omnigent_view_testing_sleep_ends_between(now, now + UInt64(remaining * 1e9)) == 1
    }
  }
#endif
