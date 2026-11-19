import Foundation
import Testing

@testable import OmnigentWorkspaceUI

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
#endif

/// The table preview of `.csv` and `.tsv` files, as the web's `DataTablePreview` sorts, filters,
/// copies and summarizes it; the core parses the file and ranks each column.
@MainActor
@Suite("Data table preview", .serialized)
struct DataTableTests {
  /// `name,amount` with an empty amount; ranks as the core gives them.
  static let table = DataTablePreview(
    columns: [
      DataTableColumn(id: 0, name: "name", type: .text, ranks: [2, 1, 3, 2]),
      DataTableColumn(id: 1, name: "amount", type: .number, ranks: [2, 0, 1, 3]),
    ],
    rows: [["Lee", "10"], ["Ada", ""], ["Zoe", "2"], ["lee", "25"]],
    totalRows: 4, totalColumns: 2)

  @Test("a header sorts ascending, then descending, then back to file order")
  func sortCycle() {
    var query = DataTableQuery()
    query.cycleSort(1)
    #expect(query.rows(of: Self.table) == [2, 0, 3, 1], "empty cells last")
    query.cycleSort(1)
    #expect(query.rows(of: Self.table) == [3, 0, 2, 1], "empty cells stay last")
    query.cycleSort(1)
    #expect(query.sort == nil)
    #expect(query.rows(of: Self.table) == [0, 1, 2, 3])
    query.cycleSort(1)
    query.cycleSort(0)
    #expect(query.sort == .init(column: 0, ascending: true), "another column starts ascending")
    #expect(query.rows(of: Self.table) == [1, 0, 3, 2], "equal names keep file order")
  }

  @Test("the system table's flip from descending to ascending goes back to file order")
  func systemHeader() {
    var query = DataTableQuery()
    query.request(.init(column: 0, ascending: true))
    query.request(.init(column: 0, ascending: false))
    #expect(query.sort == .init(column: 0, ascending: false))
    query.request(.init(column: 0, ascending: true))
    #expect(query.sort == nil)
    query.request(.init(column: 1, ascending: true))
    query.request(.init(column: 0, ascending: false))
    #expect(query.sort == .init(column: 0, ascending: false))
    query.request(nil)
    #expect(query.sort == nil)
  }

  @Test("filters keep rows whose cells contain their text, ignoring case, all of them")
  func filters() {
    var query = DataTableQuery()
    query.addFilter(0)
    query.addFilter(0)
    #expect(query.filters.count == 1, "a column has one filter")
    #expect(!query.isFiltering, "an empty filter keeps every row")
    query.filters[0].text = "  LE "
    #expect(query.rows(of: Self.table) == [0, 3])
    query.addFilter(1)
    query.filters[1].text = "2"
    #expect(query.rows(of: Self.table) == [3])
    query.cycleSort(1)
    query.removeFilter(1)
    #expect(query.rows(of: Self.table) == [0, 3], "sorted by amount")
  }

  @Test("the summary counts rows and columns, and says what the table leaves out")
  func wording() {
    #expect(Self.table.summary == "4 rows \u{00B7} 2 columns")
    #expect(Self.table.omissionNote == nil)
    var long = Self.table
    long.totalRows = 5_000
    long.totalColumns = 600
    long.encoding = "windows-1252"
    #expect(long.summary == "5,000 rows \u{00B7} 600 columns \u{00B7} windows-1252")
    #expect(
      long.omissionNote
        == "Showing the first 4 of 5,000 rows and the first 2 of 600 columns. Download the file to see all of it."
    )
    long.totalColumns = 2
    #expect(
      long.omissionNote == "Showing the first 4 of 5,000 rows. Download the file to see every row.")
    long.truncated = true
    #expect(long.summary.hasPrefix("At least 5,000 rows"))
    #expect(long.omissionNote == "Showing the first 4 rows.")
    let one = DataTablePreview(columns: [], rows: [], totalRows: 1, totalColumns: 1)
    #expect(one.summary == "1 row \u{00B7} 1 column")
  }

  @Test("a row copies tab-separated, quoting cells with tabs, breaks or quotes")
  func rowText() {
    let table = DataTablePreview(
      columns: [], rows: [["a", "b\tc", "say \"hi\"", "x\ny"]], totalRows: 1, totalColumns: 4)
    #expect(table.rowText(0) == "a\t\"b\tc\"\t\"say \"\"hi\"\"\"\t\"x\ny\"")
    #expect(table.rowText(3).isEmpty)
    #expect(table.cell(0, 9).isEmpty)
  }

  @Test("CSV and TSV files preview as a table")
  func kind() {
    #expect(FilePreviewKind.of(path: "out/results.CSV") == .dataTable)
    #expect(FilePreviewKind.of(path: "a.tsv") == .dataTable)
    #expect(FilePreviewKind.of(path: ".csv") == nil)
    #expect(FilePreviewKind.of(path: "a.csv.md") == .markdown)
  }

  #if os(macOS)
    private func viewer(_ file: WorkspaceFile) -> OffscreenWindow<FileViewerView> {
      OffscreenWindow(
        FileViewerView(file: file, source: SampleWorkspaceDataSource()), width: 800, height: 500)
    }

    @Test("a data file opens on a system table with its summary, and keeps Source")
    func viewerTable() throws {
      UserDefaults.standard.removeObject(forKey: FileViewerView.viewModeKey)
      let text = TextPreview(text: "name,amount\nLee,10\n", lineCount: 2)
      let screen = viewer(
        WorkspaceFile(
          path: "out/people.csv", byteCount: 20, preview: .text(text), dataTable: Self.table))
      defer { screen.close() }
      screen.settle()
      #expect(screen.allViews.contains { $0 is NSTableView })
      #expect(try screen.shows("4 rows \u{00B7} 2 columns"))
      #expect(try screen.shows("Zoe"))
      #expect(try screen.shows("Source"), "the Preview and Source picker shows")
    }

    @Test("a data file in another encoding shows its table, and Source says it can't")
    func viewerEncoded() throws {
      UserDefaults.standard.removeObject(forKey: FileViewerView.viewModeKey)
      var table = Self.table
      table.encoding = "windows-1252"
      table.truncated = true
      let screen = viewer(
        WorkspaceFile(
          path: "latin.csv", byteCount: 20, preview: .binary(reason: .notText), dataTable: table))
      defer { screen.close() }
      screen.settle()
      #expect(try screen.shows("windows-1252"))
      #expect(try screen.shows("The server returned the first"))
      #expect(!(try screen.shows("No Preview")))
    }

    @Test("a data file with no rows says so")
    func viewerEmpty() throws {
      UserDefaults.standard.removeObject(forKey: FileViewerView.viewModeKey)
      let screen = viewer(
        WorkspaceFile(
          path: "empty.csv", byteCount: 0, preview: .text(TextPreview(text: "", lineCount: 0))))
      defer { screen.close() }
      #expect(try screen.shows("This file has no rows. Switch to Source to see the raw file."))
    }
  #endif
}
