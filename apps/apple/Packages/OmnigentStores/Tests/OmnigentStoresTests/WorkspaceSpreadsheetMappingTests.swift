import Foundation
import OmnigentCoreFFI
import OmnigentWorkspaceUI
import Testing

@testable import OmnigentStores

/// Excel and Parquet previews from the core's bytes: the app reads the file and the core types
/// and ranks each table, as for CSV.
@Suite("Workspace spreadsheet previews")
struct WorkspaceSpreadsheetMappingTests {
  /// The web's fixtures, read by both apps' readers.
  private static let fixtures = URL(filePath: #filePath)
    .deletingLastPathComponent()  // this file
    .deletingLastPathComponent()  // OmnigentStoresTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // OmnigentStores
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // apps
    .appending(path: "web/src/shell/__fixtures__")

  @Test("a Parquet file's table is typed, ranked and named by its format")
  func parquet() throws {
    let data = try Data(contentsOf: Self.fixtures.appending(path: "sales.snappy.parquet"))
    let preview = WorkspaceMapping.preview(
      .spreadsheet(format: .parquet, data: data, truncated: false))
    guard case .spreadsheet(.parquet, .sheets(let sheets)) = preview else {
      Issue.record("the file maps to \(preview)")
      return
    }
    let table = try #require(sheets.first?.table)
    #expect(table.columns.map(\.type) == [.text, .number, .number, .date, .date, .text, .text])
    #expect(table.columns[1].ranks == [2, 1, 0], "10, 2 and an empty cell, sorted by value")
    #expect(table.summary == "3 rows \u{00B7} 7 columns \u{00B7} Parquet")
  }

  @Test("a workbook's sheets map in order, and a cut file can't be read")
  func workbook() throws {
    let data = try Data(contentsOf: Self.fixtures.appending(path: "sales.xlsx"))
    let preview = WorkspaceMapping.preview(
      .spreadsheet(format: .xlsx, data: data, truncated: false))
    guard case .spreadsheet(.xlsx, .sheets(let sheets)) = preview else {
      Issue.record("the workbook maps to \(preview)")
      return
    }
    #expect(sheets.map(\.name) == ["Sales", "Notes", "Empty"])
    #expect(sheets.first?.table?.columns.last?.name == "column 6", "the core labels a blank name")
    let cut = WorkspaceMapping.preview(.spreadsheet(format: .xlsx, data: data, truncated: true))
    guard case .spreadsheet(_, .unreadable) = cut else {
      Issue.record("a cut workbook maps to \(cut)")
      return
    }
  }
}
