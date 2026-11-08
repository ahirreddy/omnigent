import AppKit
import Darwin
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// Whether the tests run in a virtual machine, where they may put windows on screen.
enum VirtualMachine {
  static var isPresent: Bool {
    var present: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return unsafe sysctlbyname("kern.hv_vmm_present", &present, &size, nil, 0) == 0
      && present == 1
  }
}

/// Arranging orders windows on screen, so these run only in a VM (`vm-test.sh`), never on a
/// developer's Mac.
@MainActor
@Suite("Windows menu guard", .enabled(if: VirtualMachine.isPresent), .serialized)
struct WindowsMenuGuardTests {

  /// Counts the windows ordered while arranging, and changes a window at the second: AppKit
  /// brings one window front first, then walks its Windows menu list to order the rest.
  private final class Orders {
    var count = 0
    var change: (() -> Void)?

    func ordered() {
      count += 1
      if count == 2 { change?() }
    }
  }

  /// Reports each ordering, as SwiftUI can change windows when one comes back on screen.
  private final class OrderedWindow: NSWindow {
    var orders: Orders?

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
      super.order(place, relativeTo: otherWindow)
      orders?.ordered()
    }
  }

  /// Arranges four windows, making `change` to one of them while AppKit walks the rest.
  private func arrange(_ change: @escaping (NSWindow) -> Void) -> (
    changed: NSWindow, menu: [String]
  ) {
    let windows = ["B", "C changed", "D", "E"].map { title in
      let window = OrderedWindow(
        contentRect: CGRect(x: 100, y: 100, width: 300, height: 200),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.title = title
      window.orderFront(nil)
      return window
    }
    defer {
      for window in windows { window.close() }
    }
    let orders = Orders()
    orders.change = { change(windows[1]) }
    for window in windows { window.orders = orders }
    NSApp.sendAction(WindowsMenuGuard.alternateArrangeSelector, to: NSApp, from: nil)
    #expect(orders.count >= 2)
    return (windows[1], NSApp.windowsMenu?.items.map(\.title) ?? [])
  }

  @Test func aWindowRenamedWhileArrangingKeepsItsNewTitle() {
    let (changed, menu) = arrange { $0.title = "A renamed" }
    #expect(changed.title == "A renamed")
    #expect(menu.contains("A renamed"))
    #expect(!menu.contains("C changed"))
  }

  @Test func aWindowClosedWhileArrangingLeavesTheMenu() {
    let (changed, menu) = arrange { $0.close() }
    #expect(!changed.isVisible)
    #expect(!menu.contains("C changed"))
  }
}
