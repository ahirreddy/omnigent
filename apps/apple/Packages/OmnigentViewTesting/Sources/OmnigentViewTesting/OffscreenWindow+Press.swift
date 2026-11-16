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
      // Post only inside tracking: stopping the runner's own loop would end the process with a
      // false pass. In the default mode nothing tracks, so the posted up waits in the queue.
      nonisolated(unsafe) let trackedUp = mouseUp
      nonisolated(unsafe) var postedUntracked = false
      let release = Timer(timeInterval: 0.01, repeats: false) { _ in
        MainActor.assumeIsolated {
          unsafe postedUntracked = RunLoop.current.currentMode == .default
          NSApp.postEvent(unsafe trackedUp, atStart: false)
        }
      }
      RunLoop.main.add(release, forMode: .common)
      deliver(down, to: target)
      if release.isValid {
        release.invalidate()
        // A menu that opened and closed within the down took the whole click.
        guard !isMenuOpen() else { return }
        MainLoop.settle(limit: 0.03, windows: [target])
        deliver(mouseUp, to: target)
      } else if unsafe postedUntracked, !isMenuOpen(),
        let waiting = NSApp.nextEvent(
          matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
      {
        deliver(waiting, to: target)
      }
    }
  }
#endif
