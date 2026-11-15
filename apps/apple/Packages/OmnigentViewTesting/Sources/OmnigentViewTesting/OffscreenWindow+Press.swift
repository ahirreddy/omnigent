#if os(macOS)
  import AppKit

  extension OffscreenWindow {
    /// Sends an event from a run loop of its own. AppKit can stop the current loop while handling
    /// one, such as a list row with a drag source, and a test body's loop is the test runner's.
    func deliver(_ event: NSEvent, to target: NSWindow) {
      nonisolated(unsafe) let sent = event
      CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
        MainActor.assumeIsolated { target.sendEvent(unsafe sent) }
        CFRunLoopStop(CFRunLoopGetMain())
      }
      _ = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
    }

    /// Delivers a mouse down and then its up. A control that tracks the mouse inside its down
    /// takes the up, posted as its tracking loop starts; any other control gets the up once the
    /// down returns.
    /// - Parameters:
    ///   - down: The mouse down.
    ///   - mouseUp: Its mouse up.
    ///   - target: The window both go to.
    func press(_ down: NSEvent, releasedBy mouseUp: NSEvent, in target: NSWindow) {
      // Post only inside tracking: stopping the runner's own loop would end the process with a
      // false pass. Tracking runs the loop in its own mode, so its start is where to post; a
      // timer there would fire late where timers are coarse.
      nonisolated(unsafe) let trackedUp = mouseUp
      nonisolated(unsafe) var posted = false
      let tracking = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.entry.rawValue, false, 0
      ) { _, _ in
        MainActor.assumeIsolated {
          unsafe posted = true
          NSApp.postEvent(unsafe trackedUp, atStart: false)
        }
      }
      let trackingMode = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
      CFRunLoopAddObserver(CFRunLoopGetMain(), tracking, trackingMode)
      deliver(down, to: target)
      CFRunLoopObserverInvalidate(tracking)
      // A menu's tracking, or the control's, took the up.
      guard unsafe !posted else { return }
      MainLoop.settle(limit: 0.03, windows: [target])
      deliver(mouseUp, to: target)
    }
  }
#endif
