import AppKit
import ObjectiveC

/// A toolbar too narrow for its items lists the clipped ones in an overflow menu, which AppKit
/// validates on every key press and can title from a SwiftUI item that has no label. A nil menu
/// item title throws, and the throw reaching the run loop quits the app; the guard titles such
/// an item with an empty string instead.
///
/// The replacement is nonisolated for the same reason as ``ToolbarSwapGuard``'s.
enum MenuTitleGuard {
  nonisolated(unsafe) private static var isInstalled = false

  /// Guards every menu item's title from now on.
  /// - Returns: Whether AppKit had the method to guard.
  @MainActor @discardableResult
  static func install() -> Bool {
    guard unsafe !isInstalled else { return true }
    guard
      let original = unsafe class_getInstanceMethod(
        NSMenuItem.self, #selector(setter: NSMenuItem.title)),
      let replacement = unsafe class_getInstanceMethod(
        NSMenuItem.self, #selector(NSMenuItem.titleGuardSetTitle(_:)))
    else { return false }
    unsafe method_exchangeImplementations(original, replacement)
    unsafe isInstalled = true
    return true
  }
}

extension NSMenuItem {
  /// Once installed this is `setTitle:`; calling it calls AppKit's.
  @objc nonisolated fileprivate func titleGuardSetTitle(_ title: String?) {
    guard let title else {
      #if DEBUG
        ChaosLog.recordNilMenuTitle()
      #endif
      titleGuardSetTitle("")
      return
    }
    titleGuardSetTitle(title)
  }
}
