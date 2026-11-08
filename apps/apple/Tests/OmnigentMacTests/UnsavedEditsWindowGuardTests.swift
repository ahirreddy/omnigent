import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// The window guard stands in front of SwiftUI's window delegate. The window subscribes the
/// guard to each delegate notification the original answers, so a resize after the original or
/// an earlier guard is released must still reach a live delegate, or AppKit throws an
/// unrecognized selector and the app quits.
@MainActor
struct UnsavedEditsWindowGuardTests {
  private final class SwiftUIDelegate: NSObject, NSWindowDelegate {
    var resizes = 0

    func windowDidResize(_ notification: Notification) { resizes += 1 }
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    return window
  }

  private func makeGuard() -> UnsavedEditsWindowGuard {
    UnsavedEditsWindowGuard(unsaved: { [] }, save: { [] }, discard: {})
  }

  @Test func resizeReachesTheOriginalAfterAnEarlierGuardAndTheOriginalAreReleased() {
    let window = makeWindow()
    var original: SwiftUIDelegate? = SwiftUIDelegate()
    weak let tracked = original
    window.delegate = original
    var earlier: UnsavedEditsWindowGuard? = makeGuard()
    earlier?.install(on: window)
    // SwiftUI rebuilt the window's view: a new guard installs before the old one goes away.
    let current = makeGuard()
    current.install(on: window)
    earlier = nil
    original = nil

    window.setFrame(CGRect(x: 0, y: 0, width: 520, height: 340), display: false)

    #expect(window.delegate === current)
    #expect(tracked?.resizes == 1, "the original delegate missed the resize")
  }

  @Test func removingTheGuardHandsTheWindowBack() {
    let window = makeWindow()
    let original = SwiftUIDelegate()
    window.delegate = original
    let guardian = makeGuard()
    guardian.install(on: window)
    #expect(window.delegate === guardian)

    guardian.uninstall()

    #expect(window.delegate === original)
    window.setFrame(CGRect(x: 0, y: 0, width: 480, height: 320), display: false)
    #expect(original.resizes == 1)
  }
}
