import Foundation

/// What a workbook's sheet tables may still hold, in cells and characters: each sheet's table
/// is kept, so a workbook of many sparse sheets needs a cap of its own.
nonisolated struct WorkbookTableBudget {
  var cells = 1_000_000
  var chars = 10_000_000
}

/// Reads an Excel workbook's visible sheets for the table preview, as the web's `readWorkbook`
/// does: parts found through the package's relationships, every part within the inflation
/// allowance, and the sheets' tables within the workbook's budget.
nonisolated struct WorkbookReader {
  static let tooLargeSheet =
    "This sheet is too large to preview. Download the workbook to open it."
  static let pastWorkbookLimit =
    "This sheet is past what the preview holds for one workbook. Download the workbook to open it."

  private var archive: WorkbookArchive
  private var tableBudget: WorkbookTableBudget

  /// A sheet's table, a sheet past the limits, or one past the workbook's budget.
  private enum SheetResult {
    case table(DataTablePreview?)
    case message(String)
  }

  /// The visible sheets of `bytes`, in workbook order.
  /// - Parameters:
  ///   - bytes: The `.xlsx` file.
  ///   - maxBytes: The most its parts may inflate to together.
  ///   - tableBudget: What its sheets' tables may hold together.
  ///   - makeTable: Builds each sheet's table.
  /// - Returns: The sheets.
  /// - Throws: ``SpreadsheetFailure`` when the workbook can't be read.
  static func read(
    _ bytes: [UInt8], maxBytes: Int = WorkbookArchive.maxWorkbookBytes,
    tableBudget: WorkbookTableBudget = WorkbookTableBudget(),
    makeTable: SpreadsheetTableBuilder
  ) throws(SpreadsheetFailure) -> [SpreadsheetSheet] {
    do throws(WorkbookFailure) {
      var reader = Self(
        archive: try WorkbookArchive(bytes: bytes, allowance: maxBytes), tableBudget: tableBudget)
      return try reader.sheets(makeTable: makeTable)
    } catch {
      throw SpreadsheetFailure(message: error.message)
    }
  }

  private mutating func sheets(makeTable: SpreadsheetTableBuilder) throws(WorkbookFailure)
    -> [SpreadsheetSheet]
  {
    // The package's own relationships are optional: Excel's default place is the fallback.
    let root: [RelationshipsXML.Relationship]
    do throws(WorkbookFailure) {
      root = try relationships(of: "")
    } catch WorkbookFailure.tooLarge {
      throw .tooLarge
    } catch {
      root = []
    }
    let declared = Self.part(ofType: "officeDocument", in: root)
    let workbookPath =
      declared.flatMap { archive.entries[$0] == nil ? nil : $0 } ?? "xl/workbook.xml"
    let workbook = WorkbookPartXML()
    guard let workbookPart = try archive.part(workbookPath) else {
      throw .unreadable("This file isn't a readable Excel workbook.")
    }
    try workbook.parse(workbookPart)
    let relationships = try relationships(of: workbookPath)
    let context = try context(relationships, date1904: workbook.date1904)
    var tables: [String: SheetResult] = [:]
    var sheets: [SpreadsheetSheet] = []
    // One sheet at a time, so only one inflated part is held at once.
    for sheet in workbook.sheets where !sheet.hidden {
      let name = sheet.name ?? "Sheet \(sheets.count + 1)"
      let target = relationships.first { $0.id == (sheet.relationshipID ?? "") }?.target
      if let target, tables[target] == nil {
        tables[target] = try table(target, context: context, makeTable: makeTable)
      }
      let id = sheets.count
      switch target.flatMap({ tables[$0] }) {
      case .table(let table):
        sheets.append(SpreadsheetSheet(id: id, name: name, table: table))
      case .message(let message):
        sheets.append(SpreadsheetSheet(id: id, name: name, table: nil, message: message))
      case nil:
        sheets.append(SpreadsheetSheet(id: id, name: name, table: nil))
      }
    }
    return sheets
  }

  /// The shared strings, date styles and date system every sheet reads.
  private mutating func context(
    _ relationships: [RelationshipsXML.Relationship], date1904: Bool
  ) throws(WorkbookFailure) -> WorksheetContext {
    // A workbook that declares no such part may still keep it where Excel does.
    let shared = SharedStringsXML()
    let sharedPath =
      Self.part(ofType: "sharedStrings", in: relationships) ?? "xl/sharedStrings.xml"
    if let part = try archive.part(sharedPath) { try shared.parse(part) }
    let stylesPath = Self.part(ofType: "styles", in: relationships) ?? "xl/styles.xml"
    var styles: StylesXML?
    if let part = try archive.part(stylesPath) {
      let parsed = StylesXML()
      try parsed.parse(part)
      styles = parsed
    }
    return WorksheetContext(
      sharedStrings: shared.strings, dateStyles: ExcelValues.dateStyles(styles), date1904: date1904)
  }

  /// One sheet part's table, within the inflation allowance and the workbook's table budget.
  private mutating func table(
    _ target: String, context: WorksheetContext, makeTable: SpreadsheetTableBuilder
  ) throws(WorkbookFailure) -> SheetResult {
    // The workbook's tables already hold all they may; nothing more is read.
    guard tableBudget.cells > 0, tableBudget.chars > 0 else {
      return .message(Self.pastWorkbookLimit)
    }
    let worksheet = WorksheetXML(context: context)
    do throws(WorkbookFailure) {
      if let part = try archive.part(target) { try worksheet.parse(part) }
    } catch WorkbookFailure.tooLarge {
      // A sheet past the size limits is marked, and the sheets that fit still show.
      return .message(Self.tooLargeSheet)
    }
    let table = worksheet.sheetRecords.flatMap(makeTable)
    let size = table.map(Self.size) ?? (cells: 0, chars: 0)
    // A table that doesn't fit what's left isn't kept, and later sheets aren't read.
    guard size.cells <= tableBudget.cells, size.chars <= tableBudget.chars else {
      tableBudget.cells = 0
      return .message(Self.pastWorkbookLimit)
    }
    tableBudget.cells -= size.cells
    tableBudget.chars -= size.chars
    return .table(table)
  }

  /// The cells (padding included) and characters `table` holds.
  private static func size(_ table: DataTablePreview) -> (cells: Int, chars: Int) {
    let names = table.columns.reduce(into: 0) { $0 += $1.name.utf16.count }
    let chars = table.rows.reduce(into: names) { total, row in
      total += row.reduce(into: 0) { $0 += $1.utf16.count }
    }
    return (table.columns.count * (table.rows.count + 1), chars)
  }

  /// `part`'s relationships inside the archive; external targets are left out.
  private mutating func relationships(of part: String) throws(WorkbookFailure)
    -> [RelationshipsXML.Relationship]
  {
    guard let bytes = try archive.part(PackagePaths.relationships(of: part)) else { return [] }
    let parsed = RelationshipsXML()
    try parsed.parse(bytes)
    return parsed.relationships.compactMap { relationship in
      guard !relationship.external,
        let path = PackagePaths.resolve(part, relationship.target)
      else { return nil }
      // A target may percent-encode its name; the archive entry is tried as written first.
      let decoded = relationship.target.removingPercentEncoding.flatMap {
        PackagePaths.resolve(part, $0)
      }
      let found = archive.entries[path] == nil ? decoded ?? path : path
      return RelationshipsXML.Relationship(
        id: relationship.id, type: relationship.type, target: found, external: false)
    }
  }

  /// The first relationship of `type`, for example `styles`, in either Open XML namespace.
  private static func part(
    ofType type: String, in relationships: [RelationshipsXML.Relationship]
  ) -> String? {
    relationships.first { $0.type.hasSuffix("/\(type)") }?.target
  }
}
