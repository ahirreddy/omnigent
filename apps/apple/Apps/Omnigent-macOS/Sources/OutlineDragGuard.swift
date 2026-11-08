import AppKit
import ObjectiveC

/// A drag that starts on a SwiftUI list row after the list lost that row (a refresh, a filter,
/// a page loading while the mouse was down) has AppKit collect a nil item for it, and the throw
/// reaching the run loop quits the app. The guard leaves out dragged rows that have no item.
///
/// The replacement is nonisolated for the same reason as ``ToolbarSwapGuard``'s.
enum OutlineDragGuard {
  nonisolated(unsafe) private static var isInstalled = false

  /// AppKit's private method that tells the delegate which items a drag begins with.
  nonisolated static let willBeginSelector = NSSelectorFromString(
    "_sendWillBeginDraggingSession:willBeginAtPoint:forDraggedRowIndexes:")

  /// Guards every outline view's drags from now on.
  /// - Returns: Whether AppKit had the method to guard.
  @MainActor @discardableResult
  static func install() -> Bool {
    guard unsafe !isInstalled else { return true }
    guard
      let original = unsafe class_getInstanceMethod(NSOutlineView.self, willBeginSelector),
      let replacement = unsafe class_getInstanceMethod(
        NSOutlineView.self,
        #selector(NSOutlineView.outlineDragGuardSendWillBegin(_:willBeginAt:forDraggedRowIndexes:)))
    else { return false }
    unsafe method_exchangeImplementations(original, replacement)
    unsafe isInstalled = true
    return true
  }
}

extension NSOutlineView {
  private typealias ItemAtRow = @convention(c) (AnyObject, Selector, Int) -> AnyObject?

  /// Once installed this is `_sendWillBeginDraggingSession:willBeginAtPoint:forDraggedRowIndexes:`;
  /// calling it calls AppKit's. It reads rows through Objective-C messages, which carry no
  /// main-actor check.
  @objc nonisolated fileprivate func outlineDragGuardSendWillBegin(
    _ session: NSDraggingSession?, willBeginAt point: NSPoint, forDraggedRowIndexes rows: IndexSet
  ) {
    let selector = #selector(item(atRow:))
    let itemAtRow = unsafe unsafeBitCast(method(for: selector), to: ItemAtRow.self)
    let rowsWithItems = rows.filteredIndexSet { itemAtRow(self, selector, $0) != nil }
    outlineDragGuardSendWillBegin(session, willBeginAt: point, forDraggedRowIndexes: rowsWithItems)
  }
}
