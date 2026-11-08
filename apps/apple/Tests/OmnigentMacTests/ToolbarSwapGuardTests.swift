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

  /// Lets the main run loop turn until `done` or a second passes.
  private func runMainLoop(until done: () -> Bool) async throws {
    for _ in 0..<100 where !done() {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func aConstraintPassDuringASwapRunsAfterIt() async throws {
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
    try await runMainLoop { view.updates == 2 }

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

/// What the app sets on every window before the first opens.
@MainActor
struct WindowLaunchSettingsTests {
  /// Native window tabs would join a full-screen window's new windows to it and then hand them
  /// between spaces, which AppKit throws on; the app's windows have their own tab strip.
  @Test func nativeWindowTabbingIsOff() {
    #expect(!NSWindow.allowsAutomaticWindowTabbing)
  }

  /// The test host launches through the same delegate, so the guard is already in place.
  @Test func theToolbarSwapGuardIsInstalledAtLaunch() {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
      backing: .buffered, defer: true)
    var swapped = false
    ToolbarSwapGuard.swap(window) { swapped = ToolbarSwapGuard.isSwapping(window) }
    #expect(swapped)
    #expect(ToolbarSwapGuard.install(), "a second install reports the first")
  }
}

/// A narrow toolbar's overflow menu can title an item from a SwiftUI item with no label; a nil
/// title throws, and the throw quits the app.
@MainActor
struct MenuTitleGuardTests {
  @Test func aNilTitleBecomesEmpty() {
    #expect(MenuTitleGuard.install())
    let item = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")

    _ = unsafe item.perform(#selector(setter: NSMenuItem.title), with: nil)

    #expect(item.title.isEmpty)
  }

  @Test func otherTitlesAreUnchanged() {
    #expect(MenuTitleGuard.install())
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    item.title = "Right panel"

    #expect(item.title == "Right panel")
  }
}
