#if os(macOS)
  import AppKit

  extension MainLoop {
    /// What kept a turn of the loop from being idle.
    struct Activity: OptionSet {
      let rawValue: Int
      /// A run loop source or event was handled.
      static let source = Self(rawValue: 1 << 0)
      /// A one-shot run loop timer comes due before the wait's limit.
      static let timer = Self(rawValue: 1 << 1)
      /// A window had constraints or layout pending.
      static let layout = Self(rawValue: 1 << 2)
      /// A window drew what it had pending.
      static let drawing = Self(rawValue: 1 << 3)
      /// A `Task.sleep` ends before the wait's limit.
      static let sleep = Self(rawValue: 1 << 4)
    }

    /// Runs one turn of the loop, then finishes the windows' pending layout and drawing.
    /// - Parameters:
    ///   - deadline: The wait's end, as an absolute time.
    ///   - windows: Windows to check besides every shown one.
    /// - Returns: What happened, or is still due before `deadline`; empty when idle.
    static func runTurn(until deadline: CFAbsoluteTime, windows: [NSWindow]) -> Activity {
      let start = CFAbsoluteTimeGetCurrent()
      defer { SettleTrace.note(turnTook: CFAbsoluteTimeGetCurrent() - start) }
      let slice = min(turn, max(0, deadline - start))
      var activity: Activity = []
      if CFRunLoopRunInMode(.defaultMode, slice, true) == .handledSource {
        activity.insert(.source)
      }
      if TimerQueue.hasOneShot(dueBefore: deadline) { activity.insert(.timer) }
      let shown = NSApp.windows.filter(\.isVisible)
      for window in shown + windows.filter({ !$0.isVisible }) {
        activity.formUnion(finishPendingWork(window))
      }
      return activity
    }

    /// Lays out and draws what a window has pending.
    /// - Parameter window: The window.
    /// - Returns: The work it had: layout, or drawing that its display pass then did.
    static func finishPendingWork(_ window: NSWindow) -> Activity {
      guard let content = window.contentView else { return [] }
      var activity: Activity = []
      if hasPendingLayout(content) {
        activity.insert(.layout)
        SettleTrace.note(layoutIn: content)
        content.updateConstraintsForSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
      }
      // A window off every display, or transparent, may never draw; its flag then stays set,
      // which is no work to wait for.
      if window.isVisible, window.viewsNeedDisplay {
        window.displayIfNeeded()
        if window.viewsNeedDisplay {
          SettleTrace.note(stuckDrawingIn: window)
        } else {
          activity.insert(.drawing)
        }
      }
      return activity
    }

    /// Whether a view, or a shown one under it, needs its constraints updated or a layout.
    /// - Parameter root: The view.
    /// - Returns: Whether any of them does.
    static func hasPendingLayout(_ root: NSView) -> Bool {
      firstPendingLayout(under: root) != nil
    }

    /// The first view, in depth-first order, that needs its constraints updated or a layout.
    /// - Parameter root: The view to start from; hidden views and those under them are skipped.
    /// - Returns: The view, if any.
    static func firstPendingLayout(under root: NSView) -> NSView? {
      var pending: [NSView] = [root]
      while let view = pending.popLast() {
        if view.isHidden { continue }
        if view.needsLayout || view.needsUpdateConstraints { return view }
        pending.append(contentsOf: view.subviews)
      }
      return nil
    }
  }

  /// The main run loop's timers. A repeating timer, such as a poll, is not work in flight, so
  /// only a one-shot timer coming due keeps a wait going. Core Foundation lists a run loop's
  /// timers only in its description, which is read only when some timer is due.
  @MainActor
  enum TimerQueue {
    /// A reading of the description: when, the soonest fire date then, and its one-shot timers'
    /// fire dates.
    private struct Reading {
      let readAt: CFAbsoluteTime
      let soonest: CFAbsoluteTime
      let oneShots: [Double]
    }

    private static var cache: Reading?
    /// How long a reading stands while the soonest fire date stays put.
    static let cacheLife: TimeInterval = 0.01

    /// Whether a one-shot timer of the main run loop's default mode fires before `deadline`.
    /// - Parameter deadline: An absolute time.
    /// - Returns: Whether one does.
    static func hasOneShot(dueBefore deadline: CFAbsoluteTime) -> Bool {
      // Zero means no timer is scheduled.
      let soonest = CFRunLoopGetNextTimerFireDate(CFRunLoopGetMain(), .defaultMode)
      guard soonest > 0, soonest < deadline else { return false }
      let now = CFAbsoluteTimeGetCurrent()
      if let cache, cache.soonest == soonest, now - cache.readAt < cacheLife {
        return cache.oneShots.contains { $0 < deadline }
      }
      let description = CFCopyDescription(CFRunLoopGetMain()) as String? ?? ""
      let oneShots = oneShotFireDates(in: description, now: now)
      cache = Reading(readAt: now, soonest: soonest, oneShots: oneShots)
      SettleTrace.note(timers: description)
      return oneShots.contains { $0 < deadline }
    }

    /// The fire dates of the valid one-shot timers a run loop's description lists.
    /// - Parameters:
    ///   - description: `CFCopyDescription` of the run loop.
    ///   - now: The current absolute time, which the listed times are relative to.
    /// - Returns: Absolute fire dates; a timer listed in several modes appears once per mode.
    static func oneShotFireDates(in description: String, now: CFAbsoluteTime) -> [Double] {
      description.split(separator: "<CFRunLoopTimer ").dropFirst().compactMap { entry in
        guard entry.contains("valid = Yes"), let interval = number(after: "interval = ", in: entry),
          interval == 0, let fromNow = number(after: "next fire date = ", then: "(", in: entry)
        else { return nil }
        return now + fromNow
      }
    }

    /// The number after `label`, or after the first `marker` that follows `label`.
    private static func number(
      after label: String, then marker: String? = nil, in text: Substring
    ) -> Double? {
      guard var rest = text.range(of: label).map({ text[$0.upperBound...] }) else { return nil }
      if let marker {
        guard let found = rest.range(of: marker) else { return nil }
        rest = rest[found.upperBound...]
      }
      let digits = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "e" }
      return Double(digits)
    }
  }
#endif
