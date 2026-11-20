import Foundation
import Testing

@testable import OmnigentWorkspaceUI

/// Excel workbooks read for the table preview, against the web's `xlsx.test.ts` fixtures.
@Suite("Excel workbook preview")
struct SpreadsheetWorkbookTests {
  private typealias Fixtures = SpreadsheetFixtures

  @Test("every visible sheet reads in order, with numbers, dates, booleans and formulas")
  func sales() throws {
    let sheets = try Fixtures.workbook("sales.xlsx")
    #expect(sheets.map(\.name) == ["Sales", "Notes", "Empty"], "the hidden sheet is skipped")
    #expect(sheets[2].table == nil)
    let sales = try #require(sheets[0].table)
    #expect(
      sales.columns.map(\.name) == ["region", "units", "revenue", "closed", "won", "column 6"])
    #expect(
      sales.rows == [
        ["West", "10", "1234.5", "2026-03-01", "TRUE", "=B2*2"],
        ["East", "2", "99.95", "2026-01-15 09:30:00", "FALSE", ""],
        ["North", "", "0.5", "", "TRUE", ""],
      ])
    #expect(sales.totalRows == 3)
    #expect(sales.summary == "3 rows \u{00B7} 6 columns \u{00B7} Excel workbook")
    #expect(sheets[1].table?.rows == [["café, crème"], ["line one\nline two"]])
  }

  @Test("a cell without a style index takes the first cell format")
  func defaultStyle() throws {
    let sheet = Array(
      """
      <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
      <row><c t="inlineStr"><is><t>date</t></is></c></row>
      <row><c><v>45658</v></c></row><row><c s="0"><v>45658</v></c></row>
      </sheetData></worksheet>
      """.utf8)
    let styles =
      "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
      + "<cellXfs count=\"1\"><xf numFmtId=\"14\"/></cellXfs></styleSheet>"
    var parts = try Self.parts(Fixtures.workbook(sheet: sheet))
    parts.append(("xl/styles.xml", Array(styles.utf8)))
    let sheets = try WorkbookReader.read(Fixtures.storedZip(parts)) { Fixtures.table($0) }
    #expect(sheets.first?.table?.rows == [["2025-01-01"], ["2025-01-01"]])
  }

  @Test("XML with a namespace prefix, as the Open XML SDK writes it, reads too")
  func prefixed() throws {
    let report = try #require(try Fixtures.workbook("prefixed.xlsx").first)
    #expect(report.name == "Report")
    #expect(report.table?.columns.map(\.name) == ["item", "count"])
    #expect(report.table?.rows == [["pens", "12"]])
  }

  @Test(
    "a worksheet in UTF-16, or ASCII declared as UTF-16, reads",
    arguments: [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf16, .utf8])
  func encodings(encoding: String.Encoding) throws {
    let xml = Fixtures.worksheet(
      [["item"], ["café, crème"]], declaration: "<?xml version=\"1.0\" encoding=\"UTF-16\"?>")
    let bytes = try #require(xml.data(using: encoding))
    let sheets = try WorkbookReader.read(Fixtures.workbook(sheet: [UInt8](bytes))) {
      Fixtures.table($0)
    }
    #expect(sheets.first?.message == nil)
    #expect(sheets.first?.table?.rows == [["café, crème"]])
  }

  @Test("the first 500 columns of a wider sheet show, every column and row counted")
  func wide() throws {
    let wide = try #require(try Fixtures.workbook("wide520.xlsx").first?.table)
    #expect(wide.columns.count == 500)
    #expect(wide.totalColumns == 520)
    #expect(wide.totalRows == 2)
  }

  @Test("a damaged workbook, or a file that isn't one, says so")
  func unreadable() throws {
    let damaged = SpreadsheetReader.read(
      Data(try Fixtures.bytes("damaged.xlsx")), format: .xlsx, truncated: false
    ) { Fixtures.table($0) }
    #expect(damaged == .unreadable("This Excel workbook is damaged."))
    let other = SpreadsheetReader.read(Data("not a zip".utf8), format: .xlsx, truncated: false) {
      Fixtures.table($0)
    }
    guard case .unreadable(let message) = other else {
      Issue.record("a file that isn't a zip reads as \(other)")
      return
    }
    #expect(message.hasPrefix("This file isn't a readable Excel workbook."))
    let cut = SpreadsheetReader.read(Data(), format: .xlsx, truncated: true) { Fixtures.table($0) }
    #expect(
      cut
        == .unreadable(
          "This file is larger than the preview limit, so it can't be read here. "
            + "Download it to open it."))
  }

  @Test("a shared string repeated down the sheet stops being kept past the text budget")
  func sharedRepeated() throws {
    let sheet = try #require(try Fixtures.workbook("shared-repeated.xlsx").first?.table)
    // 61 rows of 32,767 characters fit two million; the 62nd is kept for the core to cut.
    #expect(sheet.rows.count == 62)
    #expect(sheet.totalRows == 1000)
  }

  @Test(
    "times, durations and a saved formula result show as Excel shows them",
    arguments: [
      ("times1900.xlsx", ["00:00:00", "1899-12-31", "12:00:00", "3", "36:00:00", "2160:00"]),
      ("times1904.xlsx", ["00:00:00", "1904-01-01", "12:00:00", "3", "36:00:00", "2160:00"]),
    ])
  func times(name: String, row: [String]) throws {
    let sheet = try #require(try Fixtures.workbook(name).first?.table)
    #expect(
      sheet.columns.map(\.name) == ["time", "date", "short time", "total", "elapsed", "minutes"])
    #expect(sheet.rows == [row])
  }

  @Test("a part that inflates past the limit marks its sheets, whatever size it declares")
  func understated() throws {
    let sheets = try Fixtures.workbook("understated.xlsx")
    #expect(sheets.map(\.name) == ["Times", "Again"])
    #expect(sheets.allSatisfy { $0.table == nil && $0.message == WorkbookReader.tooLargeSheet })
  }

  @Test("a shared part reads once, and every part counts against the workbook's allowance")
  func allowance() throws {
    let small = try Fixtures.workbook("budget.xlsx", maxBytes: 10_000)
    #expect(small.map(\.name) == ["Small", "Big", "Again"])
    #expect(small.map(\.table?.rows) == [[["pens"]], nil, [["pens"]]])
    #expect(small.map(\.message) == [nil, WorkbookReader.tooLargeSheet, nil])
    // Big fits 20,500 bytes alone, but not after the package's other parts were read.
    let tight = try Fixtures.workbook("budget.xlsx", maxBytes: 20_500)
    #expect(tight.map(\.message) == [nil, WorkbookReader.tooLargeSheet, nil])
  }

  @Test("distinct sparse sheets stop being kept once the workbook's tables fill its budget")
  func tableBudget() throws {
    let sheets = try Fixtures.workbook(
      "sparse-sheets.xlsx", tableBudget: WorkbookTableBudget(cells: 250, chars: 1_000_000))
    #expect(sheets.map(\.table?.rows.count) == [9, 9, nil, nil])
    #expect(
      sheets.map(\.message) == [
        nil, nil, WorkbookReader.pastWorkbookLimit, WorkbookReader.pastWorkbookLimit,
      ])
    #expect(
      try Fixtures.workbook("sparse-sheets.xlsx").allSatisfy { $0.table?.columns.count == 10 })
  }

  @Test("a saved blank result is blank and an uncomputed formula shows its text")
  func formulas() throws {
    #expect(
      try Fixtures.workbook("formula-results.xlsx").first?.table?.rows == [["row", "", "=B2*2"]])
  }

  @Test(
    "parts are found through the workbook's relationships",
    arguments: ["renamed-strings.xlsx", "renamed-styles.xlsx", "parent-relative-sheet.xlsx"])
  func relationships(name: String) throws {
    let sheet = try #require(try Fixtures.workbook(name).first)
    #expect(sheet.name == "Orders")
    #expect(sheet.message == nil)
    #expect(sheet.table?.columns.map(\.name) == ["item", "when"])
    #expect(sheet.table?.rows == [["pens", "2026-03-01"]])
    #expect(sheet.table?.totalRows == 1)
  }

  @Test("a relocated workbook is found through the package, and an external sheet is skipped")
  func relocated() throws {
    let sheets = try Fixtures.workbook("relocated-workbook.xlsx")
    #expect(sheets.map(\.name) == ["Orders", "Linked"])
    #expect(sheets.map(\.table?.rows) == [[["pens", "2026-03-01"]], nil])
  }

  @Test("a workbook stored without compression, whose bytes are ASCII, reads")
  func stored() throws {
    #expect(try Fixtures.workbook("ascii-stored.xlsx").contains { $0.table != nil })
  }

  /// The parts of a stored zip built by the fixtures, to add one.
  private static func parts(_ zip: [UInt8]) throws -> [(name: String, data: [UInt8])] {
    var archive = try WorkbookArchive(bytes: zip)
    var parts: [(name: String, data: [UInt8])] = []
    for name in archive.entries.keys.sorted() {
      parts.append((name, try archive.part(name) ?? []))
    }
    return parts
  }
}
