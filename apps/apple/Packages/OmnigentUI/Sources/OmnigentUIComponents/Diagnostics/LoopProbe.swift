#if DEBUG
  public import Foundation

  /// Reports state that layout keeps changing many times a second for seconds on end, the mark
  /// of a feedback loop (a dock resizing the view that measures it); a resize changes it as
  /// often, but only while the window moves. Debug builds only; nothing is recorded until a host
  /// such as the Mac app's chaos driver sets ``sink``.
  public enum LoopProbe {
    /// Receives one line per loop found.
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
      /// The latest changes' details, oldest first.
      var recent: [String] = []
    }

    private static var windows: [String: Window] = [:]
    /// Until when changes are not counted.
    private static var quietUntil: Date?

    /// Counts nothing for `seconds`: the host is resizing a window itself, which changes
    /// layout every frame. A loop that outlasts it is reported once it has gone on as long.
    public static func quiet(for seconds: TimeInterval, from now: Date = Date()) {
      quietUntil = max(quietUntil ?? now, now.addingTimeInterval(seconds))
    }

    /// Records that `name` changed; `detail` describes its state for the report.
    public static func record(
      _ name: String, at now: Date = Date(), _ detail: @autoclosure () -> String
    ) {
      guard let sink else { return }
      let detail = detail()
      HangTrace.change("\(name): \(detail)")
      if let quietUntil, now < quietUntil {
        windows[name] = nil
        return
      }
      var window = windows[name] ?? Window(start: now)
      let elapsed = now.timeIntervalSince(window.start)
      if elapsed > 1 {
        let wasBusy = window.changes >= limit && elapsed < 2
        window = Window(
          start: now, busyBefore: wasBusy ? window.busyBefore + 1 : 0, reports: window.reports,
          recent: window.recent)
      }
      window.changes += 1
      window.recent = Array((window.recent + [detail]).suffix(reportedChanges))
      if window.changes == limit, window.busyBefore + 1 >= busySeconds,
        window.reports < reportsPerName
      {
        window.reports += 1
        sink(
          "LOOP \(name) changed \(limit) times a second for \(busySeconds) seconds: "
            + window.recent.joined(separator: " | "))
      }
      windows[name] = window
    }

    /// Forgets every count, for tests.
    static func reset() {
      windows = [:]
      quietUntil = nil
    }
  }
#endif
