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
}
