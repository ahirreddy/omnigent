import AppKit
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A drag of rows a list no longer has drags only the rows it still has. A drag needs a shown
/// window and the real mouse, so the chaos replay of seed 500 checks the guard in AppKit.
@MainActor
struct TableDragGuardTests {
  @Test func installsOnThisAppKit() {
    #expect(TableDragGuard.install())
  }

  @Test func rowsPastTheEndAreLeftOut() {
    #expect(TableDragGuard.rowsStillListed([0, 1, 9], hitRow: 1, count: 2) == [0, 1])
    #expect(TableDragGuard.rowsStillListed([9], hitRow: 1, count: 2)?.isEmpty == true)
  }

  @Test func aClickedRowThatIsGoneDragsNothing() {
    #expect(TableDragGuard.rowsStillListed([0, 9], hitRow: 9, count: 8) == nil)
    #expect(TableDragGuard.rowsStillListed([0], hitRow: -1, count: 8) == nil)
  }
}
