public import Foundation
import OmnigentPlatform
private import os

/// The unified log's place for loop and stall reports, in every build:
/// `log show --last 30m --predicate 'subsystem == "ai.omnigent.performance" AND category == "hang"'`.
/// Lines hold names, row ids, counts and sizes, never what a conversation says.
nonisolated enum HangLog {
  private static let logger = Logger(subsystem: PerformanceSignposts.subsystem, category: "hang")

  static func write(_ line: String) {
    logger.fault("\(line, privacy: .public)")
  }
}

/// Reports state that layout keeps changing many times a second for seconds on end, the mark
/// of a feedback loop (a dock resizing the view that measures it); a resize changes it as
/// often, but only while the window moves. A report goes to ``sink`` when a host such as the
/// Mac app's chaos driver set one, and to the unified log otherwise.
public enum LoopProbe {
  /// Receives one line per loop found, in place of the unified log.
  public static var sink: ((String) -> Void)?
  /// Changes within a second that make it a busy second.
  static let limit = 30
  /// Busy seconds in a row that make a loop.
  static let busySeconds = 3
  /// Loops reported per name, so one that never ends is not logged on every frame.
  static let reportsPerName = 5
  /// The latest changes a report lists, enough to tell a value flipping from one growing.
  static let reportedChanges = 6

  private struct Window {
    var start: Date
    var changes = 0
    /// Busy seconds just before this one.
    var busyBefore = 0
    var reports = 0
    /// The details of the changes that complete a loop, oldest first.
    var recent: [String] = []

    /// Whether this second completes a loop still worth a report if it turns out busy.
    var mayReport: Bool { busyBefore + 1 >= busySeconds && reports < reportsPerName }
  }

  private static var windows: [HangTrace.Source: Window] = [:]
  /// Until when changes are not counted.
  private static var quietUntil: Date?

  /// Counts nothing for `seconds`: the host is resizing a window itself, which changes
  /// layout every frame. A loop that outlasts it is reported once it has gone on as long.
  public static func quiet(for seconds: TimeInterval, from now: Date = Date()) {
    quietUntil = max(quietUntil ?? now, now.addingTimeInterval(seconds))
  }

  /// Records that `name` changed. `detail` describes its state for the report and is only
  /// read for the changes a report lists, so a change costs a count and no string.
  /// - Parameters:
  ///   - name: The probed value, a literal.
  ///   - tag: Tells apart views probing the same value.
  ///   - now: The time of the change.
  ///   - detail: The state, with nothing private in it.
  public static func record(
    _ name: String, tag: Int = 0, at now: Date = Date(), _ detail: @autoclosure () -> String
  ) {
    let source = HangTrace.Source(name: name, tag: tag)
    HangTrace.tally(source)
    HangTrace.change("\(source.label): \(detail())")
    if let quietUntil, now < quietUntil {
      windows[source] = nil
      return
    }
    if windows.count >= HangTrace.keptSources { windows.removeAll(keepingCapacity: true) }
    var window = windows[source] ?? Window(start: now)
    let elapsed = now.timeIntervalSince(window.start)
    if elapsed > 1 {
      let wasBusy = window.changes >= limit && elapsed < 2
      window = Window(
        start: now, busyBefore: wasBusy ? window.busyBefore + 1 : 0, reports: window.reports)
    }
    window.changes += 1
    if window.mayReport, window.changes > limit - reportedChanges, window.changes <= limit {
      window.recent.append(detail())
    }
    if window.changes == limit, window.mayReport {
      window.reports += 1
      (sink ?? HangLog.write)(
        "LOOP \(source.label) changed \(limit) times a second for \(busySeconds) seconds: "
          + window.recent.joined(separator: " | "))
    }
    windows[source] = window
  }

  /// Forgets every count, for tests.
  static func reset() {
    windows = [:]
    quietUntil = nil
  }
}
