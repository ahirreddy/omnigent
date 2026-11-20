/// Reads a Parquet file's schema and first rows for the table preview, as the web's
/// `readParquet` does: the row count from the footer, the first 500 top-level columns, nested
/// values as JSON, and bounds on what is decoded and built.
nonisolated struct ParquetReader {
  /// The most values the selected chunks may hold: pages decode whole before the rows are cut.
  static let maxValues = 10_000_000
  /// The most uncompressed bytes the selected chunks may hold.
  static let maxBytes: Int64 = 64 * 1024 * 1024
  /// Codecs this reader decompresses: uncompressed, Snappy and gzip.
  static let readableCodecs: Set<Int64> = [0, 1, 2]

  private static let notParquet = SpreadsheetFailure(
    message: "This file isn't a readable Parquet file.")
  private static let pastMemoryLimit = SpreadsheetFailure(
    message: "Reading this file would exceed the preview's memory limit. Download it to open it.")

  let bytes: [UInt8]
  let metadata: ParquetMetadata

  /// The records of the Parquet file `bytes`, or `nil` for a file with no columns.
  /// - Parameters:
  ///   - bytes: The whole file.
  ///   - maxValues: The most values the chunks read may hold.
  /// - Returns: The records.
  /// - Throws: ``SpreadsheetFailure`` with the message to show.
  static func read(_ bytes: [UInt8], maxValues: Int = Self.maxValues) throws(SpreadsheetFailure)
    -> SpreadsheetRecords?
  {
    let reader = Self(bytes: bytes, metadata: try footer(bytes))
    return try reader.records(maxValues: maxValues)
  }

  /// The footer: `PAR1`, the file, the Thrift footer, its length and `PAR1` again.
  private static func footer(_ bytes: [UInt8]) throws(SpreadsheetFailure) -> ParquetMetadata {
    let magic = Array("PAR1".utf8)
    guard bytes.count >= 12, bytes.starts(with: magic), bytes.suffix(4).elementsEqual(magic)
    else { throw notParquet }
    let length = (0..<4).reduce(into: 0) { $0 |= Int(bytes[bytes.count - 8 + $1]) << (8 * $1) }
    let start = bytes.count - 8 - length
    guard start >= 4 else { throw notParquet }
    var reader = ThriftReader(bytes: bytes, position: start)
    let metadata: ParquetMetadata
    do {
      metadata = try ParquetMetadata(try reader.readStruct())
    } catch {
      throw notParquet
    }
    let codecs = metadata.rowGroups.flatMap { $0.columns.map(\.codec) }
    if let codec = codecs.first(where: { !readableCodecs.contains($0) }) {
      let names = ParquetMetadata.codecNames
      let name = names.indices.contains(Int(codec)) ? names[Int(codec)] : "codec \(codec)"
      throw SpreadsheetFailure(
        message:
          "This file is compressed with \(name), which the preview can't read yet. "
          + "Download it to open it.")
    }
    return metadata
  }

  private func records(maxValues: Int) throws(SpreadsheetFailure) -> SpreadsheetRecords? {
    guard !metadata.fields.isEmpty else { return nil }
    // Only the kept columns are read; the rest are counted.
    let columns = Array(metadata.fields.prefix(DataTablePreview.maxColumns))
    let nested = Set(
      columns.filter { $0.repetition == .repeated || !$0.children.isEmpty }.map(\.name))
    // Past the budget, skip nested columns first so flat columns can still show.
    let names = Set(columns.map(\.name))
    let skipNested = !withinReadBudget(names, maxValues: maxValues)
    let read = columns.filter { !(skipNested && nested.contains($0.name)) }
    if skipNested, !withinReadBudget(Set(read.map(\.name)), maxValues: maxValues) {
      throw Self.pastMemoryLimit
    }
    let rowCount = Int(clamping: max(0, min(metadata.rowCount, Int64(DataTablePreview.maxRows))))
    let values = try rows(of: read, count: rowCount)
    let header = columns.map(\.name)
    var records = [header]
    // Cells are built only while the text budget lasts; the row that passes it is the last
    // one built, and the table keeps or cuts it.
    var budget =
      DataTablePreview.maxChars
      - header.reduce(into: 0) { $0 += min($1.utf16.count, DataTablePreview.maxNameChars) }
    for row in 0..<rowCount where budget >= 0 {
      records.append(
        columns.map { column in
          let text =
            skipNested && nested.contains(column.name)
            ? ParquetText.skippedNested
            : ParquetText.cell(
              values[column.name]?[row] ?? .missing, isDate: column.meaning == .date,
              limit: max(budget, 0) + 1)
          budget -= text.utf16.count
          return text
        })
    }
    return SpreadsheetRecords(
      records: records, totalRows: Int(clamping: metadata.rowCount),
      totalColumns: metadata.fields.count, description: SpreadsheetFormat.parquet.title)
  }

  /// Whether the whole chunks of `columns` in the row groups the preview reads stay within the
  /// value and byte limits, since even a flat column's first page can hold more values than
  /// the rows it shows.
  private func withinReadBudget(_ columns: Set<String>, maxValues: Int) -> Bool {
    var rows: Int64 = 0
    var values: Int64 = 0
    var bytes: Int64 = 0
    for group in metadata.rowGroups where rows < Int64(DataTablePreview.maxRows) {
      guard group.rowCount >= 0 else { return false }
      guard group.rowCount > 0 else { continue }
      rows += group.rowCount
      for chunk in group.columns where columns.contains(chunk.path.first ?? "") {
        guard chunk.valueCount >= 0, chunk.uncompressedSize >= 0 else { return false }
        values += chunk.valueCount
        bytes += chunk.uncompressedSize
        if values > Int64(maxValues) || bytes > Self.maxBytes { return false }
      }
    }
    return true
  }

  /// The first `count` rows of each of `fields`, by name.
  private func rows(of fields: [ParquetSchemaNode], count: Int) throws(SpreadsheetFailure)
    -> [String: [ParquetValue]]
  {
    var rows: [String: [ParquetValue]] = [:]
    for field in fields { rows[field.name] = [] }
    guard !fields.isEmpty else { return rows }
    var read = 0
    for group in metadata.rowGroups where read < count {
      let needed = min(count - read, Int(clamping: group.rowCount))
      guard needed > 0 else { continue }
      for field in fields {
        let values = try groupRows(of: field, in: group, needed: needed)
        guard values.count >= needed else { throw .generic }
        rows[field.name, default: []] += values.prefix(needed)
      }
      read += needed
    }
    return rows
  }

  /// `field`'s values for the first `needed` rows of `group`.
  private func groupRows(of field: ParquetSchemaNode, in group: ParquetRowGroup, needed: Int)
    throws(SpreadsheetFailure) -> [ParquetValue]
  {
    let chunks = Dictionary(
      group.columns.map { ($0.path.joined(separator: "\u{1F}"), $0) },
      uniquingKeysWith: { first, _ in first })
    var data: [String: [ParquetValue]] = [:]
    do {
      for chain in field.leaves() {
        guard let column = ParquetLeafColumn(chain: chain), let chunk = chunks[column.node.key],
          !chunk.external
        else { throw ParquetPageFailure.malformed }
        let leaf = try ParquetPageReader(file: bytes, chunk: chunk, column: column)
          .read(rows: needed)
        data[column.node.key] = try ParquetAssembly.lists(leaf, path: column.repetitionPath)
      }
      try ParquetAssembly.nested(&data, field, depth: 0)
    } catch ParquetPageFailure.unsupportedEncoding(let name) {
      throw SpreadsheetFailure(
        message:
          "This file uses an encoding the preview can't read yet (\(name)). "
          + "Download it to open it.")
    } catch {
      throw .generic
    }
    return data[field.key] ?? []
  }
}
