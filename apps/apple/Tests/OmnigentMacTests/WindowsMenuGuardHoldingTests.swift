import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// Changes to the Windows menu wait for an arrangement to finish, then happen in order. AppKit's
/// own methods stand aside here, so no window moves; `WindowsMenuGuardTests` runs the real ones in
/// the VM.
@MainActor
@Suite(.serialized)
struct WindowsMenuGuardHoldingTests {
  private typealias ItemChange = @convention(block) (AnyObject, NSWindow?, String?, Bool) -> Void
  private typealias WindowChange = @convention(block) (AnyObject, NSWindow?) -> Void
  private typealias Arrange = @convention(block) (AnyObject, Any?) -> Void

  /// What reached AppKit, in order.
  private final class Log {
    var events: [String] = []
  }

  /// Runs `body` with AppKit's Windows menu methods logging instead, and `arranging` as what
  /// AppKit does while it arranges.
  private func withAppKitLogging(
    _ log: Log, arranging: @escaping () -> Void, body: () -> Void
  ) throws {
    #expect(WindowsMenuGuard.install())
    let change: ItemChange = { _, _, title, _ in log.events.append("change \(title ?? "")") }
    let add: ItemChange = { _, _, title, _ in log.events.append("add \(title ?? "")") }
    let remove: WindowChange = { _, _ in log.events.append("remove") }
    let arrange: Arrange = { _, _ in
      log.events.append("arrange")
      arranging()
    }
    let replacements: [String: Any] = [
      "windowsMenuGuardChange:title:filename:": change,
      "windowsMenuGuardAdd:title:filename:": add, "windowsMenuGuardRemove:": remove,
      "windowsMenuGuardArrange:": arrange, "windowsMenuGuardAlternateArrange:": arrange,
    ]
    try GuardedMethod.replacing(replacements, of: NSApplication.self, body: body)
  }

  private func window() -> NSWindow {
    NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: .borderless,
      backing: .buffered, defer: true)
  }

  private func changeAll(_ window: NSWindow) {
    NSApp.changeWindowsItem(window, title: "renamed", filename: false)
    NSApp.addWindowsItem(window, title: "added", filename: false)
    NSApp.removeWindowsItem(window)
  }

  @Test func outsideAnArrangementChangesHappenAtOnce() throws {
    let log = Log()
    let window = window()
    try withAppKitLogging(log, arranging: {}, body: { changeAll(window) })
    #expect(log.events == ["change renamed", "add added", "remove"])
  }

  /// AppKit walks its list while arranging, and a change to the list then throws and quits.
  @Test func changesWaitForAnArrangementAndKeepTheirOrder() throws {
    let log = Log()
    let window = window()
    try withAppKitLogging(
      log, arranging: { changeAll(window) }, body: { NSApp.arrangeInFront(nil) })
    #expect(log.events == ["arrange", "change renamed", "add added", "remove"])
  }

  /// Option turns the menu item into its alternate, with the same danger.
  @Test func theAlternateArrangementHoldsChangesToo() throws {
    let log = Log()
    let window = window()
    try withAppKitLogging(
      log, arranging: { NSApp.removeWindowsItem(window) },
      body: { NSApp.sendAction(WindowsMenuGuard.alternateArrangeSelector, to: NSApp, from: nil) })
    #expect(log.events == ["arrange", "remove"])
  }

  /// A change an arrangement held can cause another; it isn't lost and isn't held forever.
  @Test func anArrangementInsideAnArrangementFinishesOnce() {
    var events: [String] = []
    WindowsMenuGuard.holdingChanges {
      events.append("outer")
      WindowsMenuGuard.holdingChanges { events.append("inner") }
      #expect(WindowsMenuGuard.hold { events.append("held") })
      events.append("outer ends")
    }
    #expect(events == ["outer", "inner", "outer ends", "held"])
    #expect(!WindowsMenuGuard.hold { Issue.record("held with no arrangement") })
  }
}
