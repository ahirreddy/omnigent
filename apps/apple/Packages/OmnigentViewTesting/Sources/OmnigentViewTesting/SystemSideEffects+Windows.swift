#if os(macOS)
  public import AppKit
  import ObjectiveC
  import os

  /// Answers that belong to one window, so tests sharing the process can't answer each other's.
  extension SystemSideEffects {
    /// How the alert and panel sheets of one window answer.
    final class WindowAnswer: Sendable {
      let alert: NSApplication.ModalResponse
      let panel: NSApplication.ModalResponse

      init(alert: NSApplication.ModalResponse, panel: NSApplication.ModalResponse) {
        self.alert = alert
        self.panel = panel
      }
    }

    /// The key a window holds its answer under; only its address matters.
    private nonisolated(unsafe) static let answerKey = UnsafeMutableRawPointer.allocate(
      byteCount: 1, alignment: 1)

    /// Sets how alerts and open or save panels shown as sheets on this window, or on a sheet over
    /// it, answer, ahead of `answer(alert:panel:...)`. It outlasts `reset()` and goes away with
    /// the window, so a test's answers never reach another test's window.
    /// - Parameters:
    ///   - alert: What an alert sheet returns.
    ///   - panel: What an open or save panel sheet returns.
    ///   - window: The window, such as an `OffscreenWindow`'s.
    @MainActor
    public static func answer(
      alert: NSApplication.ModalResponse = .alertFirstButtonReturn,
      panel: NSApplication.ModalResponse = .cancel,
      for window: NSWindow
    ) {
      let answer = WindowAnswer(alert: alert, panel: panel)
      unsafe objc_setAssociatedObject(
        window, answerKey, answer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// The answer set for this window or the nearest window it is a sheet of, if any.
    static func windowAnswer(for window: NSWindow?) -> WindowAnswer? {
      // AppKit presents sheets on the main thread, which is where this is called from.
      MainActor.assumeIsolated {
        var current = window
        while let candidate = current {
          if let answer = unsafe objc_getAssociatedObject(candidate, answerKey) as? WindowAnswer {
            return answer
          }
          current = candidate.sheetParent
        }
        return nil
      }
    }

    /// What an alert sheet on this window returns: its window's answer, else the global one.
    static func alertResponse(for window: NSWindow?) -> NSApplication.ModalResponse {
      windowAnswer(for: window)?.alert ?? state.withLock { $0.alertResponse }
    }

    /// What an open or save panel sheet on this window returns: its window's answer, else the
    /// global one.
    static func panelResponse(for window: NSWindow?) -> NSApplication.ModalResponse {
      windowAnswer(for: window)?.panel ?? state.withLock { $0.panelResponse }
    }
  }
#endif
