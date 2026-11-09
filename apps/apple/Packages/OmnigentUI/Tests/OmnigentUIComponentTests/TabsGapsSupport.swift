#if os(macOS)
  import AppKit
  import OmnigentViewTesting

  extension OffscreenWindow {
    /// Presses at `start`, moves through `points` and optionally lets go. The events go to this
    /// window alone and follow a SwiftUI `DragGesture`; no system drag session starts.
    func dragGesture(
      from start: CGPoint, through points: [CGPoint], releases: Bool = true
    ) throws {
      // A window that isn't key takes the press as first mouse, and no gesture starts.
      window.makeKey()
      try sendMouse(.leftMouseDown, start)
      for point in points {
        try sendMouse(.leftMouseDragged, point)
      }
      if releases { try sendMouse(.leftMouseUp, points.last ?? start) }
    }

    /// Sends one mouse event from a run loop of its own, as `click` does: AppKit can stop the loop
    /// it handles an event in, and a test body's loop is the test runner's.
    func sendMouse(_ type: NSEvent.EventType, _ point: CGPoint) throws {
      let event = NSEvent.mouseEvent(
        with: type, location: host.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
      guard let event else { throw OffscreenWindowError.eventUnavailable }
      nonisolated(unsafe) let sent = event
      let target = window
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        MainActor.assumeIsolated { target.sendEvent(unsafe sent) }
        CFRunLoopStop(CFRunLoopGetMain())
      }
      _ = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
      settle(0.02)
    }
  }
#endif
