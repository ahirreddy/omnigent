import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A drag of rows the list no longer has begins with the rows it still has, without a throw.
@MainActor
struct OutlineDragGuardTests {
  private final class Row: NSObject {
    let name: String
    init(_ name: String) { self.name = name }
  }

  /// Two rows, and the items each drag began with.
  private final class Source: NSObject, NSOutlineViewDataSource {
    let rows = [Row("first"), Row("second")]
    var dragged: [[Any]] = []

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
      item == nil ? rows.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
      rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { false }

    /// The session is a stand-in the test never reads.
    func outlineView(
      _ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
      willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]
    ) {
      dragged.append(draggedItems)
    }
  }

  private typealias SendWillBegin =
    @convention(c) (AnyObject, Selector, AnyObject, NSPoint, AnyObject) -> Void

  @Test func aDragOfARowNoLongerListedBeginsWithTheRest() throws {
    #expect(OutlineDragGuard.install())
    let source = Source()
    let outline = NSOutlineView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
    outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    outline.dataSource = source
    outline.reloadData()
    #expect(outline.numberOfRows == 2)

    let selector = OutlineDragGuard.willBeginSelector
    #expect(outline.responds(to: selector))
    let send = unsafe unsafeBitCast(outline.method(for: selector), to: SendWillBegin.self)
    send(outline, selector, NSObject(), .zero, IndexSet([0, 5]) as AnyObject)

    let items = try #require(source.dragged.first)
    #expect(items.compactMap { ($0 as? Row)?.name } == ["first"])
  }
}
