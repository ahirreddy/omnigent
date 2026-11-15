#if os(macOS)
  import Foundation
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
    /// Whether a turn sleeps in the run loop until its end instead of polling: cheaper on the CPU
    /// where timers are precise.
    static let sleepingTurns = ProcessInfo.processInfo.environment["OMNIGENT_WAIT_TURNS"] == "sleep"
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
#endif
