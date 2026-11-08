import AppKit
import ObjectiveC

/// A drag from a SwiftUI list starts with the rows picked at mouse-down. When the list shrinks
/// before the drag begins (a refresh, a filter, a page loading), AppKit then asks for rows past
/// its end, and the throw reaching the run loop quits the app. The guard drags only the rows the
/// table still has, and no drag at all when the clicked row is gone.
///
/// The replacements are nonisolated for the same reason as ``ToolbarSwapGuard``'s.
enum TableDragGuard {
  nonisolated(unsafe) private static var isInstalled = false

  /// AppKit's private methods that start a drag of rows from a mouse-down.
  nonisolated static let flockedSelector = NSSelectorFromString(
    "_performFlockedDragOfIndexes:hitRow:event:")
  nonisolated static let classicSelector = NSSelectorFromString(
    "_performClassicDragOfIndexes:hitRow:event:")

  /// Guards every table and outline view's row drags from now on.
  /// - Returns: Whether AppKit had the methods to guard.
  @MainActor @discardableResult
  static func install() -> Bool {
    guard unsafe !isInstalled else { return true }
    guard
      let flocked = unsafe class_getInstanceMethod(NSTableView.self, flockedSelector),
      let flockedGuard = unsafe class_getInstanceMethod(
        NSTableView.self, #selector(NSTableView.tableDragGuardFlocked(_:hitRow:event:))),
      let classic = unsafe class_getInstanceMethod(NSTableView.self, classicSelector),
      let classicGuard = unsafe class_getInstanceMethod(
        NSTableView.self, #selector(NSTableView.tableDragGuardClassic(_:hitRow:event:)))
    else { return false }
    unsafe method_exchangeImplementations(flocked, flockedGuard)
    unsafe method_exchangeImplementations(classic, classicGuard)
    unsafe isInstalled = true
    return true
  }

  /// The rows of `rows` a table of `count` rows still has, or `nil` when `hitRow` is gone.
  nonisolated static func rowsStillListed(_ rows: IndexSet, hitRow: Int, count: Int) -> IndexSet? {
    guard (0..<count).contains(hitRow) else { return nil }
    return rows.filteredIndexSet { (0..<count).contains($0) }
  }
}

extension NSTableView {
  /// The table's row count, read through an Objective-C message, which carries no main-actor
  /// check.
  nonisolated private var tableDragGuardRowCount: Int {
    value(forKey: "numberOfRows") as? Int ?? 0
  }

  /// Once installed this is `_performFlockedDragOfIndexes:hitRow:event:`; calling it calls
  /// AppKit's.
  @objc nonisolated fileprivate func tableDragGuardFlocked(
    _ rows: IndexSet, hitRow: Int, event: NSEvent?
  ) -> Bool {
    guard
      let listed = TableDragGuard.rowsStillListed(
        rows, hitRow: hitRow, count: tableDragGuardRowCount)
    else { return false }
    return tableDragGuardFlocked(listed, hitRow: hitRow, event: event)
  }

  /// Once installed this is `_performClassicDragOfIndexes:hitRow:event:`; calling it calls
  /// AppKit's.
  @objc nonisolated fileprivate func tableDragGuardClassic(
    _ rows: IndexSet, hitRow: Int, event: NSEvent?
  ) -> Bool {
    guard
      let listed = TableDragGuard.rowsStillListed(
        rows, hitRow: hitRow, count: tableDragGuardRowCount)
    else { return false }
    return tableDragGuardClassic(listed, hitRow: hitRow, event: event)
  }
}
