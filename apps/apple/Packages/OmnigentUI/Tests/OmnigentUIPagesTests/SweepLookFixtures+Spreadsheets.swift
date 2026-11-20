import Foundation
import SwiftUI

@testable import OmnigentWorkspaceUI

/// Generic data for the Excel and Parquet table previews.
@MainActor
extension SweepLookFixtures {
  /// A workbook of three sheets on its first, the table the CSV preview uses.
  static var spreadsheetSheets: some View {
    UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
    var sales = LookFixtures.salesTable(totalRows: 12)
    sales.format = SpreadsheetFormat.xlsx.title
    let sheets = [
      SpreadsheetSheet(id: 0, name: "Sales", table: sales),
      SpreadsheetSheet(id: 1, name: "Regions", table: nil),
      SpreadsheetSheet(id: 2, name: "Archive", table: nil, message: WorkbookReader.tooLargeSheet),
    ]
    return FileViewerView(
      file: WorkspaceFile(
        path: "reports/sales.xlsx", byteCount: 18_432,
        preview: .spreadsheet(format: .xlsx, preview: .sheets(sheets))),
      source: SampleWorkspaceDataSource())
  }

  /// A Parquet file in a compression the preview can't read, offering Download.
  static var spreadsheetUnreadable: some View {
    var actions = WorkspaceActions.none
    actions.download = { _ in }
    let message =
      "This file is compressed with ZSTD, which the preview can't read yet. Download it to open it."
    return FileViewerView(
      file: WorkspaceFile(
        path: "exports/events.parquet", byteCount: 2_241,
        preview: .spreadsheet(format: .parquet, preview: .unreadable(message))),
      source: SampleWorkspaceDataSource(), actions: actions)
  }
}
