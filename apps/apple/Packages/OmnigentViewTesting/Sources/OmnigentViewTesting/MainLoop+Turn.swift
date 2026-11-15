#if os(macOS)
  import AppKit
  import OmnigentViewTestingBootstrap

  extension MainLoop {
    /// What a turn of the loop did; empty when it was idle.
    struct Activity: OptionSet {
      let rawValue: Int
      /// A run loop source or event was handled.
      static let source = Self(rawValue: 1 << 0)
      /// Work was queued for the main actor: a task started or resumed.
      static let mainActorWork = Self(rawValue: 1 << 1)
      /// A window had constraints or layout pending.
      static let layout = Self(rawValue: 1 << 2)
      /// A window drew what it had pending.
      static let drawing = Self(rawValue: 1 << 3)
      /// A `Task.sleep` ends before the wait's limit.
      static let sleep = Self(rawValue: 1 << 4)
    }

    /// Runs one short turn of the loop and finishes the windows' pending layout. Timers due in
    /// the turn simply run in it; one scheduled for later is not work, since apps and AppKit
    /// always have some.
    /// - Parameters:
    ///   - deadline: The wait's end, as an absolute time.
    ///   - windows: The windows whose layout and drawing count, with their sheets and children.
    /// - Returns: What the turn did; empty when it was idle.
    static func runTurn(until deadline: CFAbsoluteTime, windows: [NSWindow]) -> Activity {
      let start = CFAbsoluteTimeGetCurrent()
      defer { SettleTrace.note(turnTook: CFAbsoluteTimeGetCurrent() - start) }
      let watched = withSheetsAndChildren(windows)
      let drawingBefore = watched.map { $0.isVisible && $0.viewsNeedDisplay }
      let queuedBefore = omnigent_view_testing_main_actor_jobs()
      var activity: Activity = []
      let slice = min(turn, max(0, deadline - start))
      if CFRunLoopRunInMode(.defaultMode, slice, true) == .handledSource {
        activity.insert(.source)
      }
      if omnigent_view_testing_main_actor_jobs() != queuedBefore { activity.insert(.mainActorWork) }
      for (window, neededDrawing) in zip(watched, drawingBefore) {
        // The loop's own display pass draws a window; a flag that never clears is no work, as
        // with a transparent window off every display.
        if neededDrawing, !window.viewsNeedDisplay { activity.insert(.drawing) }
        if let content = window.contentView, finishPendingLayout(content) {
          activity.insert(.layout)
        }
      }
      return activity
    }

    /// The windows, each followed by the sheets over it and its child windows.
    static func withSheetsAndChildren(_ windows: [NSWindow]) -> [NSWindow] {
      var found: [NSWindow] = []
      var pending = windows.reversed() as [NSWindow]
      while let window = pending.popLast() {
        guard !found.contains(where: { $0 === window }) else { continue }
        found.append(window)
        pending.append(contentsOf: (window.childWindows ?? []).reversed())
        if let sheet = window.attachedSheet { pending.append(sheet) }
      }
      return found
    }

    /// Lays out what a view and those under it have pending.
    /// - Parameter content: A window's content view.
    /// - Returns: Whether anything was pending.
    static func finishPendingLayout(_ content: NSView) -> Bool {
      guard hasPendingLayout(content) else { return false }
      SettleTrace.note(layoutIn: content)
      content.updateConstraintsForSubtreeIfNeeded()
      content.layoutSubtreeIfNeeded()
      return true
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
#endif
