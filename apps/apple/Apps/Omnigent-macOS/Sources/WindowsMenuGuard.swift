import AppKit
import ObjectiveC

/// Window > Arrange in Front walks AppKit's list of Windows menu entries and orders each window
/// front. Ordering a window can make SwiftUI retitle, open or close one, which re-sorts or edits
/// that list mid-walk, and the throw quits the app. The guard holds those changes until the
/// arrangement is done, then makes them in order.
///
/// The replacements are nonisolated for the same reason as ``ToolbarSwapGuard``'s.
enum WindowsMenuGuard {
  nonisolated(unsafe) private static var isInstalled = false
  nonisolated(unsafe) private static var isArranging = false
  /// The Windows menu changes held while windows are arranged.
  nonisolated(unsafe) private static var held: [() -> Void] = []

  /// AppKit's Arrange in Front with Option held.
  nonisolated static let alternateArrangeSelector = NSSelectorFromString(
    "alternateArrangeInFront:")

  /// Guards Arrange in Front from now on.
  /// - Returns: Whether AppKit had the methods to guard.
  @MainActor @discardableResult
  static func install() -> Bool {
    guard unsafe !isInstalled else { return true }
    let pairs = [
      (
        #selector(NSApplication.arrangeInFront(_:)),
        #selector(NSApplication.windowsMenuGuardArrange(_:))
      ),
      (alternateArrangeSelector, #selector(NSApplication.windowsMenuGuardAlternateArrange(_:))),
      (
        #selector(NSApplication.changeWindowsItem(_:title:filename:)),
        #selector(NSApplication.windowsMenuGuardChange(_:title:filename:))
      ),
      (
        #selector(NSApplication.addWindowsItem(_:title:filename:)),
        #selector(NSApplication.windowsMenuGuardAdd(_:title:filename:))
      ),
      (
        #selector(NSApplication.removeWindowsItem(_:)),
        #selector(NSApplication.windowsMenuGuardRemove(_:))
      ),
    ]
    var originals: [Method] = unsafe []
    var replacements: [Method] = unsafe []
    for (original, replacement) in pairs {
      guard let originalMethod = unsafe class_getInstanceMethod(NSApplication.self, original),
        let replacementMethod = unsafe class_getInstanceMethod(NSApplication.self, replacement)
      else { return false }
      unsafe originals.append(originalMethod)
      unsafe replacements.append(replacementMethod)
    }
    for index in unsafe originals.indices {
      unsafe method_exchangeImplementations(originals[index], replacements[index])
    }
    unsafe isInstalled = true
    return true
  }

  /// Runs `arrange`, then the Windows menu changes it caused.
  nonisolated static func holdingChanges(_ arrange: () -> Void) {
    guard unsafe !isArranging else {
      arrange()
      return
    }
    unsafe isArranging = true
    arrange()
    unsafe isArranging = false
    let changes = unsafe held
    unsafe held = []
    for change in changes { change() }
  }

  /// Holds `change` while windows are arranged.
  /// - Returns: Whether it was held; otherwise the caller makes it now.
  nonisolated static func hold(_ change: @escaping () -> Void) -> Bool {
    guard unsafe isArranging else { return false }
    unsafe held.append(change)
    return true
  }
}

extension NSApplication {
  /// Once installed this is `arrangeInFront:`; calling it calls AppKit's.
  @objc nonisolated fileprivate func windowsMenuGuardArrange(_ sender: Any?) {
    WindowsMenuGuard.holdingChanges { windowsMenuGuardArrange(sender) }
  }

  /// Once installed this is `alternateArrangeInFront:`; calling it calls AppKit's.
  @objc nonisolated fileprivate func windowsMenuGuardAlternateArrange(_ sender: Any?) {
    WindowsMenuGuard.holdingChanges { windowsMenuGuardAlternateArrange(sender) }
  }

  /// Once installed this is `changeWindowsItem:title:filename:`; calling it calls AppKit's.
  @objc nonisolated fileprivate func windowsMenuGuardChange(
    _ window: NSWindow?, title: String?, filename: Bool
  ) {
    let change = { self.windowsMenuGuardChange(window, title: title, filename: filename) }
    if !WindowsMenuGuard.hold(change) { change() }
  }

  /// Once installed this is `addWindowsItem:title:filename:`; calling it calls AppKit's.
  @objc nonisolated fileprivate func windowsMenuGuardAdd(
    _ window: NSWindow?, title: String?, filename: Bool
  ) {
    let add = { self.windowsMenuGuardAdd(window, title: title, filename: filename) }
    if !WindowsMenuGuard.hold(add) { add() }
  }

  /// Once installed this is `removeWindowsItem:`; calling it calls AppKit's.
  @objc nonisolated fileprivate func windowsMenuGuardRemove(_ window: NSWindow?) {
    let remove = { self.windowsMenuGuardRemove(window) }
    if !WindowsMenuGuard.hold(remove) { remove() }
  }
}
