#if os(macOS)
  import AppKit

  /// Why waits took their whole limit. With `OMNIGENT_SETTLE_TRACE=1` each wait that did prints
  /// to standard error what kept its turns busy, for the first few hundred such waits.
  @MainActor
  enum SettleTrace {
    static let isOn = ProcessInfo.processInfo.environment["OMNIGENT_SETTLE_TRACE"] == "1"
    static let printLimit = 300
    private static var counts: [String: Int] = [:]
    private static var details: [String: Int] = [:]
    private static var printed = 0

    /// Starts tracing one wait.
    static func begin() {
      guard isOn else { return }
      counts = [:]
      details = [:]
    }

    /// Counts one turn's activity.
    /// - Parameter activity: What kept the turn busy.
    static func note(_ activity: MainLoop.Activity) {
      guard isOn else { return }
      let names: [(MainLoop.Activity, String)] = [
        (.source, "source"), (.timer, "timer"), (.layout, "layout"), (.drawing, "drawing"),
        (.sleep, "sleep"),
      ]
      for (bit, name) in names where activity.contains(bit) { counts[name, default: 0] += 1 }
      if activity.isEmpty { counts["idle", default: 0] += 1 }
    }

    /// Names the first view under `root` with layout pending.
    /// - Parameter root: A window's content view.
    static func note(layoutIn root: NSView) {
      guard isOn, let view = MainLoop.firstPendingLayout(under: root) else { return }
      let window = (unsafe root.window).map { String(describing: type(of: $0)) } ?? "no window"
      let flag = view.needsUpdateConstraints ? "constraints" : "layout"
      details["\(flag): \(type(of: view)) in \(window)", default: 0] += 1
    }

    /// Lists the run loop's timers by their callouts, once some timer came due in a wait.
    /// - Parameter description: The main run loop's description.
    static func note(timers description: String) {
      guard isOn else { return }
      for entry in description.split(separator: "<CFRunLoopTimer ").dropFirst() {
        guard let callout = entry.range(of: "callout = ") else { continue }
        let interval = entry.contains("interval = 0,") ? "once" : "repeating"
        let name = entry[callout.upperBound...].prefix(100)
        details["timer \(interval): \(name)", default: 0] += 1
      }
    }

    /// Prints the wait's trace when it took its whole limit.
    /// - Parameters:
    ///   - name: The kind of wait.
    ///   - limit: Its limit, in seconds.
    ///   - reachedLimit: Whether it took all of it.
    static func end(_ name: String, limit: TimeInterval, reachedLimit: Bool) {
      guard isOn, reachedLimit, printed < printLimit else { return }
      printed += 1
      let turns = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      let causes = details.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) x\($0.value)" }
      let line =
        "settle-trace \(name) limit=\(limit)s turns: \(turns.joined(separator: " "))"
        + (causes.isEmpty ? "" : "\n  " + causes.joined(separator: "\n  "))
      FileHandle.standardError.write(Data((line + "\n").utf8))
    }
  }
#endif
