#if os(macOS)
  public import AppKit

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
    /// takes the up posted during that tracking; any other control gets the up once the down
    /// returns, even when a busy main thread let the up's timer fire first.
    /// - Parameters:
    ///   - down: The mouse down.
    ///   - mouseUp: Its mouse up.
    ///   - target: The window both go to.
    ///   - isMenuOpen: Whether the down opened a menu, whose own tracking answers the up.
    public func press(
      _ down: NSEvent, releasedBy mouseUp: NSEvent, in target: NSWindow,
      isMenuOpen: () -> Bool
    ) {
      // Post only inside tracking, which takes the up from the queue; the timer waits out any
      // turn in the default mode, where nothing tracks. Otherwise the up goes to the window as the
      // down did: taken from NSApp's queue it reaches what watches it, a transient popover too.
      nonisolated(unsafe) let trackedUp = mouseUp
      nonisolated(unsafe) var posted = false
      let release = Timer(timeInterval: 0.01, repeats: true) { _ in
        MainActor.assumeIsolated {
          guard RunLoop.current.currentMode != .default, !(unsafe posted) else { return }
          unsafe posted = true
          NSApp.postEvent(unsafe trackedUp, atStart: false)
        }
      }
      RunLoop.main.add(release, forMode: .common)
      deliver(down, to: target)
      release.invalidate()
      // Tracking took the posted up; a menu that opened and closed within the down took it all.
      guard !(unsafe posted), !isMenuOpen() else { return }
      MainLoop.settle(limit: 0.03, windows: [target])
      deliver(mouseUp, to: target)
    }
  }
#endif
