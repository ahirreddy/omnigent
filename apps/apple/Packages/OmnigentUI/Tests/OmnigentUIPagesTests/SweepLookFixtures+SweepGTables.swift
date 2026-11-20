import Foundation
import SwiftUI

@testable import OmnigentWorkspaceUI

/// Generic data for the table find sweep G added.
@MainActor
extension SweepLookFixtures {
  /// A table's find open on "north": its cells marked, the second one found now.
  static var tableFind: some View {
    let table = LookFixtures.salesTable(totalRows: 12)
    var find = DataTableFind()
    find.isShown = true
    find.text = "north"
    find.search(table, rows: Array(table.rows.indices))
    find.step(forward: true)
    return DataTableView(table: table, find: find)
  }
}
