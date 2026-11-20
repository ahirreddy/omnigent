public import Foundation

/// A binary data file read into tables (`workspace::SpreadsheetFormat`).
nonisolated public enum SpreadsheetFormat: Hashable, Sendable {
  /// An Excel workbook (`.xlsx`): a table per visible sheet.
  case xlsx
  /// A Parquet file: one table.
  case parquet

  /// The format of `path`, by its extension; `nil` for other files.
  /// - Parameter path: The file.
  /// - Returns: The format.
  public static func of(path: String) -> Self? {
    let name = WorkspacePaths.name(of: path).lowercased()
    guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return nil }
    switch name[name.index(after: dot)...] {
    case "xlsx": return .xlsx
    case "parquet": return .parquet
    default: return nil
    }
  }

  /// What the file is, for the viewer's header and the table's summary.
  public var title: String {
    switch self {
    case .xlsx: "Excel workbook"
    case .parquet: "Parquet"
    }
  }
}

/// A sheet's records before the core types and ranks them (web `tableFromRecords`'s input).
nonisolated public struct SpreadsheetRecords: Hashable, Sendable {
  /// The header, then the kept rows.
  public var records: [[String]]
  /// Data rows in the sheet, kept or not.
  public var totalRows: Int
  /// Columns in the sheet's widest row, kept or not.
  public var totalColumns: Int
  /// What the table came from, for example `Parquet`.
  public var description: String
  /// The reader already cut text from the records.
  public var textCut: Bool

  /// Records.
  /// - Parameters:
  ///   - records: The header, then the kept rows.
  ///   - totalRows: Data rows, kept or not.
  ///   - totalColumns: Columns in the widest row.
  ///   - description: What the table came from.
  ///   - textCut: The reader cut text.
  public init(
    records: [[String]], totalRows: Int, totalColumns: Int, description: String,
    textCut: Bool = false
  ) {
    self.records = records
    self.totalRows = totalRows
    self.totalColumns = totalColumns
    self.description = description
    self.textCut = textCut
  }
}

/// Builds a table from a sheet's records: the app's core types and ranks the columns.
public typealias SpreadsheetTableBuilder = @Sendable (SpreadsheetRecords) -> DataTablePreview?

/// One sheet of a workbook, or a Parquet file's one table.
nonisolated public struct SpreadsheetSheet: Hashable, Sendable, Identifiable {
  /// Its place in the workbook, from 0.
  public var id: Int
  /// Its name.
  public var name: String
  /// Its table; `nil` for an empty sheet or one that couldn't be read.
  public var table: DataTablePreview?
  /// Why it has no table, for example that it is too large to preview.
  public var message: String?

  /// A sheet.
  /// - Parameters:
  ///   - id: Its place, from 0.
  ///   - name: Its name.
  ///   - table: Its table.
  ///   - message: Why it has no table.
  public init(id: Int, name: String, table: DataTablePreview?, message: String? = nil) {
    self.id = id
    self.name = name
    self.table = table
    self.message = message
  }
}

/// What the viewer shows for an Excel workbook or a Parquet file.
nonisolated public enum SpreadsheetPreview: Hashable, Sendable {
  /// The sheets, in workbook order; a Parquet file has one.
  case sheets([SpreadsheetSheet])
  /// Why the file can't be read, offering Download.
  case unreadable(String)
}

/// A file that can't be read, with the message the viewer shows.
nonisolated struct SpreadsheetFailure: Error, Hashable {
  let message: String

  /// The file is damaged or isn't what its name says, beyond a reader's own message.
  static let generic = Self(
    message: "This file couldn't be read. Download it to open it elsewhere.")
}

/// Reads Excel workbooks and Parquet files into tables, as the web's `SpreadsheetPreview` does.
nonisolated public enum SpreadsheetReader {
  /// The tables of a workbook or Parquet file the server returned.
  /// - Parameters:
  ///   - data: The bytes the server returned.
  ///   - format: The file's format.
  ///   - truncated: The server returned only the start of the file.
  ///   - makeTable: Builds a table from records.
  /// - Returns: The sheets, or why the file can't be read.
  public static func read(
    _ data: Data, format: SpreadsheetFormat, truncated: Bool,
    makeTable: SpreadsheetTableBuilder
  ) -> SpreadsheetPreview {
    // Both formats keep their index at the end of the file, which a partial read lacks.
    guard !truncated else {
      return .unreadable(
        "This file is larger than the preview limit, so it can't be read here. "
          + "Download it to open it.")
    }
    let bytes = [UInt8](data)
    do throws(SpreadsheetFailure) {
      switch format {
      case .xlsx:
        return .sheets(try WorkbookReader.read(bytes, makeTable: makeTable))
      case .parquet:
        let table = try ParquetReader.read(bytes).flatMap(makeTable)
        return .sheets([SpreadsheetSheet(id: 0, name: format.title, table: table)])
      }
    } catch {
      return .unreadable(error.message)
    }
  }
}
