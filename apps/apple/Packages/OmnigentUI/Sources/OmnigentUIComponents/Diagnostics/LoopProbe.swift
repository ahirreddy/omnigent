#if DEBUG
  import Foundation

  /// Reports state that layout keeps changing many times a second, the mark of a feedback loop
  /// (a dock resizing the view that measures it). Debug builds only; nothing is recorded until a
  /// host such as the Mac app's chaos driver sets ``sink``.
  public enum LoopProbe {
    /// Receives one line per loop found.
    public static var sink: ((String) -> Void)?
    /// Changes within a second that count as a loop.
    static let limit = 30
    /// Loops reported per name, so one that never ends is not logged on every frame.
    static let reportsPerName = 5

    private struct Window {
      var start: Date
      var changes = 0
      var reports = 0
    }

    private static var windows: [String: Window] = [:]

    /// Records that `name` changed; `detail` describes its state for the report.
    static func record(_ name: String, at now: Date = Date(), _ detail: @autoclosure () -> String) {
      guard let sink else { return }
      var window = windows[name] ?? Window(start: now)
      if now.timeIntervalSince(window.start) > 1 {
        window = Window(start: now, reports: window.reports)
      }
      window.changes += 1
      if window.changes == limit, window.reports < reportsPerName {
        window.reports += 1
        sink("LOOP \(name) changed \(limit) times within a second: \(detail())")
      }
      windows[name] = window
    }

    /// Forgets every count, for tests.
    static func reset() {
      windows = [:]
    }
  }
#endif
