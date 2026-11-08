import AppKit
import ObjectiveC

/// A SwiftUI list's table keeps row numbers from a mouse-down: the rows a drag picked, the row
/// a context menu opened on. When the list shrinks meanwhile (a refresh, a filter, a page
/// loading), AppKit asks for rows past its end, and the throw quits the app. The guard drags
/// only the rows the table still has, no drag at all when the clicked row is gone, and draws no
/// menu highlight for a row that is gone.
///
/// The replacements are nonisolated for the same reason as ``ToolbarSwapGuard``'s.
enum TableRowGuard {
  nonisolated(unsafe) private static var isInstalled = false

  /// AppKit's private methods that start a drag of rows from a mouse-down.
  nonisolated static let flockedSelector = NSSelectorFromString(
    "_performFlockedDragOfIndexes:hitRow:event:")
  nonisolated static let classicSelector = NSSelectorFromString(
    "_performClassicDragOfIndexes:hitRow:event:")
  /// The outline drawn around the row a context menu is open on.
  nonisolated static let menuHighlightSelector = NSSelectorFromString(
    "_regularContextMenuHighlightPathForRow:")

  /// Guards every table and outline view's row drags and menu highlights from now on.
  /// - Returns: Whether AppKit had the methods to guard.
  @MainActor @discardableResult
  static func install() -> Bool {
    guard unsafe !isInstalled else { return true }
    let pairs = [
      (flockedSelector, #selector(NSTableView.tableRowGuardFlocked(_:hitRow:event:))),
      (classicSelector, #selector(NSTableView.tableRowGuardClassic(_:hitRow:event:))),
      (menuHighlightSelector, #selector(NSTableView.tableRowGuardMenuHighlight(forRow:))),
    ]
    var originals: [Method] = unsafe []
    var replacements: [Method] = unsafe []
    for (original, replacement) in pairs {
      guard let originalMethod = unsafe class_getInstanceMethod(NSTableView.self, original),
        let replacementMethod = unsafe class_getInstanceMethod(NSTableView.self, replacement)
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

  /// The rows of `rows` a table of `count` rows still has, or `nil` when `hitRow` is gone.
  nonisolated static func rowsStillListed(_ rows: IndexSet, hitRow: Int, count: Int) -> IndexSet? {
    guard (0..<count).contains(hitRow) else { return nil }
    return rows.filteredIndexSet { (0..<count).contains($0) }
  }
}

extension NSTableView {
  /// The table's row count, read through an Objective-C message, which carries no main-actor
  /// check.
  nonisolated private var tableRowGuardRowCount: Int {
    value(forKey: "numberOfRows") as? Int ?? 0
  }

  /// Once installed this is `_performFlockedDragOfIndexes:hitRow:event:`; calling it calls
  /// AppKit's.
  @objc nonisolated fileprivate func tableRowGuardFlocked(
    _ rows: IndexSet, hitRow: Int, event: NSEvent?
  ) -> Bool {
    guard
      let listed = TableRowGuard.rowsStillListed(
        rows, hitRow: hitRow, count: tableRowGuardRowCount)
    else { return false }
    return tableRowGuardFlocked(listed, hitRow: hitRow, event: event)
  }

  /// Once installed this is `_performClassicDragOfIndexes:hitRow:event:`; calling it calls
  /// AppKit's.
  @objc nonisolated fileprivate func tableRowGuardClassic(
    _ rows: IndexSet, hitRow: Int, event: NSEvent?
  ) -> Bool {
    guard
      let listed = TableRowGuard.rowsStillListed(
        rows, hitRow: hitRow, count: tableRowGuardRowCount)
    else { return false }
    return tableRowGuardClassic(listed, hitRow: hitRow, event: event)
  }

  /// Once installed this is `_regularContextMenuHighlightPathForRow:`; calling it calls
  /// AppKit's. No path draws no outline.
  @objc nonisolated fileprivate func tableRowGuardMenuHighlight(forRow row: Int) -> NSBezierPath? {
    guard (0..<tableRowGuardRowCount).contains(row) else { return nil }
    return tableRowGuardMenuHighlight(forRow: row)
  }
}
