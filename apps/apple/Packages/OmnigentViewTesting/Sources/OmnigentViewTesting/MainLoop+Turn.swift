#if os(macOS)
  import AppKit

  extension MainLoop {
    /// What a turn of the loop did; empty when it was idle.
    struct Activity: OptionSet {
      let rawValue: Int
      /// A run loop source or event was handled.
      static let source = Self(rawValue: 1 << 0)
      /// A window had constraints or layout pending.
      static let layout = Self(rawValue: 1 << 2)
      /// A window drew what it had pending.
      static let drawing = Self(rawValue: 1 << 3)
      /// One of the views' timed pauses ends before the wait's limit.
      static let pause = Self(rawValue: 1 << 4)
      /// A layer in a window runs an animation that ends, such as a list's rows sliding.
      static let animation = Self(rawValue: 1 << 5)
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
      var activity: Activity = []
      let end = min(start + turn, deadline)
      if WaitStats.sleepingTurns {
        let result = CFRunLoopRunInMode(.defaultMode, max(0, end - start), true)
        if result == .handledSource { activity.insert(.source) }
      } else if poll(until: end) {
        activity.insert(.source)
      }
      for (window, neededDrawing) in zip(watched, drawingBefore) {
        // The loop's own display pass draws a window; a flag that never clears is no work, as
        // with a transparent window off every display.
        if neededDrawing, !window.viewsNeedDisplay { activity.insert(.drawing) }
        if let content = window.contentView, finishPendingLayout(content) {
          activity.insert(.layout)
        }
      }
      // Only a turn that is otherwise idle looks through the layers.
      if activity.isEmpty, watched.contains(where: hasEndingAnimation) {
        activity.insert(.animation)
      }
      return activity
    }

    /// Runs whole passes of the loop until `end`, never sleeping in one: a sleep wakes late where
    /// timers are coarse, by 15 to 90 ms in a VM.
    /// - Parameter end: When to stop, as an absolute time.
    /// - Returns: Whether a source or event was handled.
    static func poll(until end: CFAbsoluteTime) -> Bool {
      var handled = false
      repeat {
        if runPass(until: end) { handled = true }
        sched_yield()
      } while CFAbsoluteTimeGetCurrent() < end
      return handled
    }

    /// Runs one pass of the main run loop, its observers' layout, display and commit before
    /// waiting included, and ends it there instead of letting it sleep.
    /// - Parameter end: When to give up on reaching the observers: a source signalled on every
    ///   pass keeps the loop from ever waiting.
    /// - Returns: Whether a source or event was handled.
    static func runPass(until end: CFAbsoluteTime) -> Bool {
      let main = CFRunLoopGetMain()
      // Last among the observers before waiting, it ends the pass and wakes the wait it ends.
      let passEnd = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max
      ) { _, _ in
        CFRunLoopStop(main)
        CFRunLoopWakeUp(main)
      }
      CFRunLoopAddObserver(main, passEnd, .defaultMode)
      defer { CFRunLoopObserverInvalidate(passEnd) }
      var handled = false
      while true {
        switch CFRunLoopRunInMode(.defaultMode, 1, true) {
        case .handledSource: handled = true
        case .stopped, .finished, .timedOut: return handled
        @unknown default: return handled
        }
        // A source ended the pass before its wait; run on to the observers.
        guard CFRunLoopObserverIsValid(passEnd), CFAbsoluteTimeGetCurrent() < end else {
          return handled
        }
      }
    }

    /// Whether a layer of the window runs an animation that will end; a looping one, such as a
    /// spinner's, is no work to wait for.
    /// - Parameter window: The window.
    /// - Returns: Whether one does.
    static func hasEndingAnimation(in window: NSWindow) -> Bool {
      guard let root = window.contentView?.layer else { return false }
      var pending: [CALayer] = [root]
      while let layer = pending.popLast() {
        for key in layer.animationKeys() ?? [] {
          guard let animation = layer.animation(forKey: key) else { continue }
          if animation.repeatCount < 1_000, animation.repeatDuration < 1_000 { return true }
        }
        pending.append(contentsOf: layer.sublayers ?? [])
      }
      return false
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
