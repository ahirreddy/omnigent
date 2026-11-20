import Foundation

/// What a data table's column holds (`workspace::DataColumnType`).
nonisolated public enum DataColumnType: String, Hashable, Sendable {
  /// Numbers, `1,234.5` and `25%` included.
  case number
  /// ISO dates, or dates and times.
  case date
  /// Anything else.
  case text
}

/// One column of a data table.
nonisolated public struct DataTableColumn: Hashable, Sendable, Identifiable {
  /// Its place, from 0.
  public var id: Int
  /// Its name.
  public var name: String
  /// What it holds.
  public var type: DataColumnType
  /// Each row's place in the column's ascending order, from the core: 0 for an empty cell, else
  /// from 1, equal cells sharing one.
  public var ranks: [UInt32]

  /// A column.
  public init(id: Int, name: String, type: DataColumnType, ranks: [UInt32]) {
    self.id = id
    self.name = name
    self.type = type
    self.ranks = ranks
  }
}

/// A `.csv` or `.tsv` file as its table preview shows it (`workspace::DataTable`).
nonisolated public struct DataTablePreview: Hashable, Sendable {
  /// The columns, in file order.
  public var columns: [DataTableColumn]
  /// The kept rows, each as wide as ``columns``.
  public var rows: [[String]]
  /// Data rows in the file, kept or not.
  public var totalRows: Int
  /// Fields in the file's widest row, kept or not.
  public var totalColumns: Int
  /// How the bytes were decoded, for example `utf-8` or `windows-1252`.
  public var encoding: String
  /// The format the summary names in place of the encoding, for example `Parquet`.
  public var format: String?
  /// Text past the preview's budget was cut from a column name or the first row.
  public var textCut: Bool
  /// The server sent only the start of the file, so ``totalRows`` is a lower bound.
  public var truncated: Bool

  /// Rows the preview keeps; the rest are only counted (`workspace::DATA_TABLE_MAX_ROWS`).
  static let maxRows = 1000
  /// Columns the preview keeps.
  static let maxColumns = 500
  /// Characters of cell text the preview keeps.
  static let maxChars = 2_000_000
  /// Longest a column name is kept.
  static let maxNameChars = 1000

  /// A table.
  public init(
    columns: [DataTableColumn], rows: [[String]], totalRows: Int, totalColumns: Int,
    encoding: String = "utf-8", format: String? = nil, textCut: Bool = false,
    truncated: Bool = false
  ) {
    self.columns = columns
    self.rows = rows
    self.totalRows = totalRows
    self.totalColumns = totalColumns
    self.encoding = encoding
    self.format = format
    self.textCut = textCut
    self.truncated = truncated
  }

  /// `row`'s cell in `column`; empty past its end.
  public func cell(_ row: Int, _ column: Int) -> String {
    guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
    return rows[row][column]
  }

  /// "1,204 rows · 6 columns", with "At least" for a cut file, and the format (`Parquet`) or
  /// the encoding when it isn't UTF-8.
  public var summary: String {
    let rowCount = "\(truncated ? "At least " : "")\(Self.count(totalRows, "row"))"
    let source = format ?? (encoding == "utf-8" ? nil : encoding)
    let sourceNote = source.map { " \u{00B7} \($0)" } ?? ""
    return "\(rowCount) \u{00B7} \(Self.count(totalColumns, "column"))\(sourceNote)"
  }

  /// What the table leaves out, "Showing the first 1,000 of 5,000 rows. Download the file to
  /// see every row.", and whether text was cut short; `nil` when it shows the whole file.
  public var omissionNote: String? {
    let shown = rows.count
    var notes: [String] = []
    if shown < totalRows {
      notes.append(
        truncated
          ? "the first \(shown.formatted()) rows"
          : "the first \(shown.formatted()) of \(totalRows.formatted()) rows")
    }
    let columnsCut = columns.count < totalColumns
    if columnsCut {
      notes.append("the first \(columns.count.formatted()) of \(totalColumns.formatted()) columns")
    }
    guard !notes.isEmpty || textCut else { return nil }
    var sentences: [String] = []
    if !notes.isEmpty { sentences.append("Showing \(notes.joined(separator: " and ")).") }
    if textCut { sentences.append("Text past the preview's limit is cut short.") }
    // A cut file says so in the viewer's own banner.
    if !truncated {
      let rest = columnsCut || textCut ? "all of it" : "every row"
      sentences.append("Download the file to see \(rest).")
    }
    return sentences.joined(separator: " ")
  }

  /// `row` as tab-separated text, quoting cells that hold a tab, line break or quote.
  public func rowText(_ row: Int) -> String {
    guard rows.indices.contains(row) else { return "" }
    return rows[row].map { cell in
      cell.contains(where: { "\t\n\r\"".contains($0) })
        ? "\"\(cell.replacing("\"", with: "\"\""))\"" : cell
    }
    .joined(separator: "\t")
  }

  private static func count(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(count == 1 ? noun : "\(noun)s")"
  }
}

/// How a data table's rows are sorted and filtered. Sorting and filtering apply to the rows the
/// table keeps, not the whole file.
nonisolated public struct DataTableQuery: Hashable, Sendable {
  /// A column's order.
  public struct Sort: Hashable, Sendable {
    /// The column.
    public var column: Int
    /// Ascending, else descending.
    public var ascending: Bool

    /// A sort.
    public init(column: Int, ascending: Bool) {
      self.column = column
      self.ascending = ascending
    }
  }

  /// Rows whose cell in `column` contains `text`, ignoring case.
  public struct Filter: Hashable, Sendable, Identifiable {
    /// The column.
    public var column: Int
    /// What the cell must contain.
    public var text: String

    /// The column.
    public var id: Int { column }

    /// A filter.
    public init(column: Int, text: String = "") {
      self.column = column
      self.text = text
    }
  }

  /// The order; `nil` keeps the file's.
  public var sort: Sort?
  /// The filters, in the order they were added; every one must match.
  public var filters: [Filter]

  /// A query.
  public init(sort: Sort? = nil, filters: [Filter] = []) {
    self.sort = sort
    self.filters = filters
  }

  /// A column header's click: ascending, then descending, then back to file order.
  public mutating func cycleSort(_ column: Int) {
    guard let sort, sort.column == column else {
      self.sort = Sort(column: column, ascending: true)
      return
    }
    self.sort = sort.ascending ? Sort(column: column, ascending: false) : nil
  }

  /// The order a system table's header asks for. It turns a descending column ascending on a
  /// click, which here goes back to file order instead, as the web's header does.
  public mutating func request(_ requested: Sort?) {
    guard let requested else {
      sort = nil
      return
    }
    if let sort, sort.column == requested.column, !sort.ascending, requested.ascending {
      self.sort = nil
    } else {
      sort = requested
    }
  }

  /// Adds a filter on `column`, once.
  public mutating func addFilter(_ column: Int) {
    guard !filters.contains(where: { $0.column == column }) else { return }
    filters.append(Filter(column: column))
  }

  /// Removes the filter on `column`.
  public mutating func removeFilter(_ column: Int) {
    filters.removeAll { $0.column == column }
  }

  /// Whether a filter with text applies.
  public var isFiltering: Bool { filters.contains { !Self.needle($0.text).isEmpty } }

  /// The rows `table` shows, by index into its rows: those every filter matches, in the sort's
  /// order (by the core's ranks, then file order), with empty cells last either way.
  public func rows(of table: DataTablePreview) -> [Int] {
    let active = filters.map { (column: $0.column, needle: Self.needle($0.text)) }
      .filter { !$0.needle.isEmpty }
    var shown = table.rows.indices.filter { row in
      active.allSatisfy { table.cell(row, $0.column).lowercased().contains($0.needle) }
    }
    guard let sort, let column = table.columns.first(where: { $0.id == sort.column }) else {
      return shown
    }
    let rank = { (row: Int) -> UInt32 in
      column.ranks.indices.contains(row) ? column.ranks[row] : 0
    }
    shown.sort { first, second in
      let (firstRank, secondRank) = (rank(first), rank(second))
      if (firstRank == 0) != (secondRank == 0) { return secondRank == 0 }
      if firstRank != secondRank {
        return sort.ascending ? firstRank < secondRank : firstRank > secondRank
      }
      return first < second
    }
    return shown
  }

  private static func needle(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }
}
