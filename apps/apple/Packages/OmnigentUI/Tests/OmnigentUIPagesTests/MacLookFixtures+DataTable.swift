import Foundation
import SwiftUI

@testable import OmnigentWorkspaceUI

extension LookFixtures {
  // MARK: Data table

  /// A small sales export: text, a date, two number columns and a percentage.
  static func salesTable(totalRows: Int = 12, truncated: Bool = false) -> DataTablePreview {
    let rows: [[String]] = [
      ["North", "2026-01-15", "1,204", "12.5%", "Steady"],
      ["South", "2026-01-15", "980", "-3%", ""],
      ["East", "2026-02-01", "2,310", "8%", "New office"],
      ["West", "2026-02-01", "", "", "Waiting on figures"],
      ["North", "2026-03-01", "1,388", "15.3%", "Best quarter so far"],
      ["South", "2026-03-01", "1,012", "3.3%", ""],
      ["East", "2026-04-01", "2,145", "-7.1%", "Supplier delay"],
      ["West", "2026-04-01", "760", "1%", ""],
      ["North", "2026-05-01", "1,450", "4.5%", ""],
      ["South", "2026-05-01", "1,101", "8.8%", "Promotion"],
      ["East", "2026-06-01", "2,402", "12%", ""],
      ["West", "2026-06-01", "812", "6.8%", ""],
    ]
    let names = ["region", "month", "revenue", "growth", "note"]
    let types: [DataColumnType] = [.text, .date, .number, .number, .text]
    let columns = names.indices.map { index in
      DataTableColumn(
        id: index, name: names[index], type: types[index],
        ranks: ranks(rows.map { $0[index] }, numeric: types[index] == .number))
    }
    return DataTablePreview(
      columns: columns, rows: rows, totalRows: totalRows, totalColumns: names.count,
      truncated: truncated)
  }

  /// Ranks as the core gives them, for this fixture's plain numbers and text.
  private static func ranks(_ cells: [String], numeric: Bool) -> [UInt32] {
    func key(_ cell: String) -> Double {
      Double(cell.replacing(",", with: "").replacing("%", with: "")) ?? 0
    }
    let present = cells.indices.filter { !cells[$0].isEmpty }
    let ordered = present.sorted {
      numeric ? key(cells[$0]) < key(cells[$1]) : cells[$0].lowercased() < cells[$1].lowercased()
    }
    var ranks = [UInt32](repeating: 0, count: cells.count)
    var rank: UInt32 = 0
    var previous: String?
    for index in ordered {
      if previous?.lowercased() != cells[index].lowercased() { rank += 1 }
      previous = cells[index]
      ranks[index] = rank
    }
    return ranks
  }

  /// The file viewer on a CSV file: its header with Preview and Source, then the table.
  static var dataTableViewer: some View {
    let text = TextPreview(text: "region,month,revenue,growth,note\n", lineCount: 13)
    return FileViewerView(
      file: WorkspaceFile(
        path: "reports/sales.csv", byteCount: 1_024, preview: .text(text),
        dataTable: salesTable()),
      source: SampleWorkspaceDataSource())
  }

  /// A long export's table, sorted by revenue, highest first, and filtered by region.
  static var dataTableFiltered: some View {
    var query = DataTableQuery(sort: .init(column: 2, ascending: false))
    query.addFilter(0)
    query.filters[0].text = "north"
    return DataTableView(table: salesTable(totalRows: 5_000), query: query)
  }
}
