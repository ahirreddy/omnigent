import Foundation

@testable import OmnigentWorkspaceUI

/// The web's spreadsheet fixtures (`web/src/shell/__fixtures__`), written by openpyxl and
/// pyarrow or built by hand, so both readers are checked against the same files.
nonisolated enum SpreadsheetFixtures {
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent()  // this file
    .deletingLastPathComponent()  // OmnigentWorkspaceUITests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // OmnigentWorkspaceUI
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()  // apple
    .deletingLastPathComponent()  // apps
    .appending(path: "web/src/shell/__fixtures__")

  static func bytes(_ name: String) throws -> [UInt8] {
    [UInt8](try Data(contentsOf: directory.appending(path: name)))
  }

  /// A table as the core builds one from records, without its types and ranks: names
  /// labeled, rows padded to the widest, at most 500 columns.
  static func table(_ records: SpreadsheetRecords) -> DataTablePreview? {
    guard let header = records.records.first else { return nil }
    let rows = Array(records.records.dropFirst())
    let width = min(500, rows.map(\.count).reduce(header.count, max))
    let columns = (0..<width).map { index in
      let name = index < header.count ? header[index] : ""
      return DataTableColumn(
        id: index,
        name: name.trimmingCharacters(in: .whitespaces).isEmpty
          ? "column \(index + 1)" : name, type: .text, ranks: [])
    }
    let padded = rows.map { row in
      Array(row.prefix(width)) + Array(repeating: "", count: max(0, width - row.count))
    }
    return DataTablePreview(
      columns: columns, rows: padded, totalRows: records.totalRows,
      totalColumns: max(records.totalColumns, width), format: records.description,
      textCut: records.textCut)
  }

  /// The sheets of the workbook fixture `name`, read with the test table builder.
  static func workbook(
    _ name: String, maxBytes: Int = WorkbookArchive.maxWorkbookBytes,
    tableBudget: WorkbookTableBudget = WorkbookTableBudget()
  ) throws -> [SpreadsheetSheet] {
    try WorkbookReader.read(
      try bytes(name), maxBytes: maxBytes, tableBudget: tableBudget
    ) { table($0) }
  }

  /// A stored (uncompressed) zip of `parts`, with the header fields the reader uses.
  static func storedZip(_ parts: [(name: String, data: [UInt8])]) -> [UInt8] {
    var locals: [UInt8] = []
    var directory: [UInt8] = []
    for part in parts {
      let name = Array(part.name.utf8)
      var local = little(0x0403_4B50, 4) + Array(repeating: 0, count: 26)
      local.replaceSubrange(18..<22, with: little(part.data.count, 4))
      local.replaceSubrange(22..<26, with: little(part.data.count, 4))
      local.replaceSubrange(26..<28, with: little(name.count, 2))
      var central = little(0x0201_4B50, 4) + Array(repeating: 0, count: 42)
      central.replaceSubrange(20..<24, with: little(part.data.count, 4))
      central.replaceSubrange(24..<28, with: little(part.data.count, 4))
      central.replaceSubrange(28..<30, with: little(name.count, 2))
      central.replaceSubrange(42..<46, with: little(locals.count, 4))
      directory += central + name
      locals += local + name + part.data
    }
    var end = little(0x0605_4B50, 4) + Array(repeating: 0, count: 18)
    end.replaceSubrange(8..<10, with: little(parts.count, 2))
    end.replaceSubrange(10..<12, with: little(parts.count, 2))
    end.replaceSubrange(12..<16, with: little(directory.count, 4))
    end.replaceSubrange(16..<20, with: little(locals.count, 4))
    return locals + directory + end
  }

  /// A workbook whose one sheet, `S1`, is `sheet`.
  static func workbook(sheet: [UInt8]) -> [UInt8] {
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
    let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    let workbook =
      "<workbook xmlns=\"\(main)\" xmlns:r=\"\(relationships)\"><sheets>"
      + "<sheet name=\"S1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>"
    let rels =
      "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
      + "<Relationship Id=\"rId1\" Type=\"\(relationships)/worksheet\" "
      + "Target=\"worksheets/sheet1.xml\"/></Relationships>"
    return storedZip([
      ("xl/workbook.xml", Array(workbook.utf8)),
      ("xl/_rels/workbook.xml.rels", Array(rels.utf8)),
      ("xl/worksheets/sheet1.xml", sheet),
    ])
  }

  /// A worksheet of inline-text cells, one row per entry of `rows`.
  static func worksheet(_ rows: [[String]], declaration: String = "") -> String {
    let cells = rows.map { row in
      "<row>"
        + row.map { "<c t=\"inlineStr\"><is><t>\($0)</t></is></c>" }.joined() + "</row>"
    }
    return declaration
      + "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"
      + "<sheetData>\(cells.joined())</sheetData></worksheet>"
  }

  private static func little(_ value: Int, _ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
  }
}
