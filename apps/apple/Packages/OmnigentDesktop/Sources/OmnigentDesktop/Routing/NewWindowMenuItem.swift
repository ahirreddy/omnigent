import AppKit

/// File > New Window (⇧⌘N), which opens a server window on the default server through
/// SwiftUI's `openWindow` even when no window is open to provide one.
enum NewWindowMenuItem {
  /// Chooses the item. Returns whether the menu has one.
  @discardableResult
  static func perform(in menu: NSMenu? = NSApp.mainMenu) -> Bool {
    guard let menu else { return false }
    for (index, item) in menu.items.enumerated() {
      if isNewWindow(item) {
        menu.performActionForItem(at: index)
        return true
      }
      if perform(in: item.submenu) { return true }
    }
    return false
  }

  /// SwiftUI records ⇧⌘N as "n" with Shift or as "N" without it.
  static func isNewWindow(_ item: NSMenuItem) -> Bool {
    let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
    switch item.keyEquivalent {
    case "n": return modifiers == [.command, .shift]
    case "N": return modifiers == .command || modifiers == [.command, .shift]
    default: return false
    }
  }
}
