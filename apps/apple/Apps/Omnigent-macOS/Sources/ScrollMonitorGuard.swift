#if OMNIGENT_CHROMIUM
  import AppKit
  import ObjectiveC

  /// AppKit resumes a scroll view's frame-sync monitor from a block on the main queue, and
  /// asserts if the window it captured when the scroll began has no screen by then: the
  /// assertion's exception reaches the run loop and quits the app (seen in chaos runs, without a
  /// way to reproduce it on demand). The guard skips that resume; a window on no screen has no
  /// frames to sync. The monitor is private AppKit API, so only the Developer ID edition, which
  /// no store review reads, installs it.
  ///
  /// The replacement is nonisolated for the same reason as ``ToolbarSwapGuard``'s.
  enum ScrollMonitorGuard {
    nonisolated(unsafe) private static var isInstalled = false
    private static let className = "_NSScrollingConcurrentVBLMonitor"

    /// Guards every scroll monitor's resume from now on.
    /// - Returns: Whether AppKit had the monitor and method to guard.
    @MainActor @discardableResult
    static func install() -> Bool {
      guard unsafe !isInstalled else { return true }
      let resume = NSSelectorFromString("resume")
      let guarded = #selector(NSObject.scrollMonitorGuardResume)
      guard let monitor = NSClassFromString(className),
        let original = unsafe class_getInstanceMethod(monitor, resume),
        let replacement = unsafe class_getInstanceMethod(NSObject.self, guarded),
        unsafe class_addMethod(
          monitor, guarded, method_getImplementation(replacement),
          method_getTypeEncoding(replacement)),
        let added = unsafe class_getInstanceMethod(monitor, guarded)
      else { return false }
      unsafe method_exchangeImplementations(original, added)
      unsafe isInstalled = true
      return true
    }

    /// Whether `monitor`'s captured window is on a screen, read through Objective-C messages;
    /// `true` when the monitor no longer answers them, so AppKit's own resume runs.
    nonisolated static func windowHasScreen(_ monitor: NSObject) -> Bool {
      let constantData = NSSelectorFromString("constantData")
      let window = NSSelectorFromString("window")
      guard monitor.responds(to: constantData),
        let data = monitor.value(forKey: "constantData") as? NSObject, data.responds(to: window)
      else { return true }
      guard let window = data.value(forKey: "window") as? NSWindow else { return false }
      return window.value(forKey: "screen") != nil
    }
  }

  extension NSObject {
    /// Once installed this is the scroll monitor's `resume`; calling it calls AppKit's.
    @objc nonisolated fileprivate func scrollMonitorGuardResume() {
      guard ScrollMonitorGuard.windowHasScreen(self) else { return }
      scrollMonitorGuardResume()
    }
  }
#endif
