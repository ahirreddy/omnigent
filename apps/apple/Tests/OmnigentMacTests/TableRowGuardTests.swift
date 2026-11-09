// The replaced method takes the Objective-C type.
// swiftlint:disable legacy_objc_type

import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A drag of rows a list no longer has drags only the rows it still has, and a menu opened on a
/// row that is gone draws no highlight. A drag needs a shown window and the real mouse, so chaos
/// runs check that part in AppKit.
@MainActor
@Suite(.serialized)
struct TableRowGuardTests {
  /// Three rows, the one column's cells plain text fields.
  private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { 3 }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
      NSTextField(labelWithString: "row \(row)")
    }
  }

  @Test func installsOnThisAppKit() {
    #expect(TableRowGuard.install())
  }

  @Test func rowsPastTheEndAreLeftOut() {
    #expect(TableRowGuard.rowsStillListed([0, 1, 9], hitRow: 1, count: 2) == [0, 1])
    #expect(TableRowGuard.rowsStillListed([9], hitRow: 1, count: 2)?.isEmpty == true)
  }

  @Test func aClickedRowThatIsGoneDragsNothing() {
    #expect(TableRowGuard.rowsStillListed([0, 9], hitRow: 9, count: 8) == nil)
    #expect(TableRowGuard.rowsStillListed([0], hitRow: -1, count: 8) == nil)
  }

  /// AppKit throws for a row past the end, which quits the app from a draw.
  @Test func aMenuHighlightForARowThatIsGoneDrawsNothing() throws {
    #expect(TableRowGuard.install())
    let rows = Rows()
    let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
    table.addTableColumn(NSTableColumn(identifier: .init("title")))
    table.dataSource = rows
    table.delegate = rows
    let window = NSWindow(
      contentRect: table.frame, styleMask: .borderless, backing: .buffered, defer: true)
    window.contentView = table
    table.reloadData()
    #expect(table.numberOfRows == 3)

    typealias HighlightPath = @convention(c) (NSTableView, Selector, Int) -> NSBezierPath?
    let selector = TableRowGuard.menuHighlightSelector
    let path = unsafe unsafeBitCast(table.method(for: selector), to: HighlightPath.self)
    #expect(path(table, selector, 3) == nil)
    #expect(path(table, selector, -1) == nil)
    #expect(path(table, selector, 2) != nil)
  }

  /// Runs a guarded drag method with AppKit's drag replaced, so no real drag starts.
  private func drag(
    _ selector: Selector, replacing appKit: String, _ rows: IndexSet, hitRow: Int
  ) throws -> (result: Bool, passedOn: [IndexSet]) {
    #expect(TableRowGuard.install())
    let source = Rows()
    let table = NSTableView(frame: CGRect(x: 0, y: 0, width: 200, height: 120))
    table.addTableColumn(NSTableColumn(identifier: .init("title")))
    table.dataSource = source
    table.reloadData()
    var passedOn: [IndexSet] = []
    let spy: @convention(block) (AnyObject, NSIndexSet, Int, NSEvent?) -> Bool = { _, rows, _, _ in
      passedOn.append(rows as IndexSet)
      return true
    }
    typealias Drag = @convention(c) (NSTableView, Selector, NSIndexSet, Int, NSEvent?) -> Bool
    let run = unsafe unsafeBitCast(table.method(for: selector), to: Drag.self)
    let result = try GuardedMethod.replacing([appKit: spy], of: NSTableView.self) {
      run(table, selector, rows as NSIndexSet, hitRow, nil)
    }
    return (result, passedOn)
  }

  /// A drag starts only on the rows the list still has.
  @Test(arguments: [
    (TableRowGuard.flockedSelector, "tableRowGuardFlocked:hitRow:event:"),
    (TableRowGuard.classicSelector, "tableRowGuardClassic:hitRow:event:"),
  ])
  func aDragPassesOnOnlyTheListedRows(selector: Selector, appKit: String) throws {
    let dragged = try drag(selector, replacing: appKit, [0, 2, 9], hitRow: 2)
    #expect(dragged.result)
    #expect(dragged.passedOn == [[0, 2]])

    let gone = try drag(selector, replacing: appKit, [0, 9], hitRow: 9)
    #expect(!gone.result)
    #expect(gone.passedOn.isEmpty, "a drag started on a row that is gone")
  }
}

// swiftlint:enable legacy_objc_type
