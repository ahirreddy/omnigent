import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A constraint pass nested in a toolbar swap reruns SwiftUI's swap, which unobserves the old
/// toolbar twice and quits the app; the guard holds such passes until the swap returns.
@MainActor
struct ToolbarSwapGuardTests {
  private final class CountingView: NSView {
    var updates = 0

    override func updateConstraints() {
      updates += 1
      super.updateConstraints()
    }
  }

  private func makeWindow() -> (NSWindow, CountingView) {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
      styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    let view = CountingView()
    window.contentView = view
    view.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
    window.updateConstraintsIfNeeded()
    view.updates = 0
    return (window, view)
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }

  @Test func aConstraintPassDuringASwapRunsAfterIt() async {
    #expect(ToolbarSwapGuard.install())
    let (window, view) = makeWindow()
    view.needsUpdateConstraints = true
    window.updateConstraintsIfNeeded()
    #expect(view.updates == 1, "outside a swap the pass runs at once")

    view.needsUpdateConstraints = true
    ToolbarSwapGuard.swap(window) {
      window.updateConstraintsIfNeeded()
      #expect(view.updates == 1, "the pass ran inside the swap")
    }
    await drainMainQueue()

    #expect(view.updates == 2, "the held pass never ran")
  }

  @Test func settingTheToolbarStillSetsIt() {
    #expect(ToolbarSwapGuard.install())
    let (window, _) = makeWindow()
    let toolbar = NSToolbar(identifier: "swap-guard-test")

    window.toolbar = toolbar
    #expect(window.toolbar === toolbar)
    #expect(!ToolbarSwapGuard.isSwapping(window))

    window.toolbar = nil
    #expect(window.toolbar == nil)
  }
}
