import AppKit
import ObjectiveC

/// SwiftUI swaps a window's toolbar by unobserving the old one and then setting the new one.
/// When that set lays the window out again (a full-screen window's titlebar, a sheet's dimming
/// mask), the nested constraint pass reruns SwiftUI's swap, which unobserves the old toolbar a
/// second time and throws, quitting the app. While a window sets its toolbar, its constraint
/// passes wait for the next turn of the run loop instead.
@MainActor
enum ToolbarSwapGuard {
  private static var swapping: Set<ObjectIdentifier> = []
  private static var isInstalled = false

  /// Guards every window's toolbar swaps from now on.
  /// - Returns: Whether AppKit had the methods to guard.
  @discardableResult
  static func install() -> Bool {
    guard !isInstalled else { return true }
    let pairs = [
      (#selector(setter: NSWindow.toolbar), #selector(NSWindow.swapGuardSetToolbar(_:))),
      (
        #selector(NSWindow.updateConstraintsIfNeeded),
        #selector(NSWindow.swapGuardUpdateConstraintsIfNeeded)
      ),
    ]
    var exchanges: [(Method, Method)] = unsafe []
    for (original, replacement) in pairs {
      guard let from = unsafe class_getInstanceMethod(NSWindow.self, original),
        let into = unsafe class_getInstanceMethod(NSWindow.self, replacement)
      else { return false }
      unsafe exchanges.append((from, into))
    }
    for unsafe (from, into) in unsafe exchanges {
      unsafe method_exchangeImplementations(from, into)
    }
    isInstalled = true
    return true
  }

  /// Whether `window` is setting its toolbar.
  static func isSwapping(_ window: NSWindow) -> Bool {
    swapping.contains(ObjectIdentifier(window))
  }

  /// Runs `body`, AppKit's toolbar set, with `window`'s constraint passes held until after it.
  static func swap(_ window: NSWindow, _ body: () -> Void) {
    let key = ObjectIdentifier(window)
    let isOutermost = swapping.insert(key).inserted
    defer { if isOutermost { swapping.remove(key) } }
    body()
  }
}

extension NSWindow {
  /// Once installed this is `setToolbar:`; calling it calls AppKit's.
  @objc fileprivate func swapGuardSetToolbar(_ toolbar: NSToolbar?) {
    ToolbarSwapGuard.swap(self) { swapGuardSetToolbar(toolbar) }
  }

  /// Once installed this is `updateConstraintsIfNeeded`; calling it calls AppKit's.
  @objc fileprivate func swapGuardUpdateConstraintsIfNeeded() {
    guard ToolbarSwapGuard.isSwapping(self) else {
      swapGuardUpdateConstraintsIfNeeded()
      return
    }
    // The constraints stay marked as needing an update; this pass runs after the swap.
    DispatchQueue.main.async { [weak self] in self?.updateConstraintsIfNeeded() }
  }
}
