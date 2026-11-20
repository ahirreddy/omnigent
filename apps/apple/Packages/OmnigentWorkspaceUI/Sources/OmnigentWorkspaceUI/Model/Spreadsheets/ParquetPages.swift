/// Why a column chunk's pages can't be read.
nonisolated enum ParquetPageFailure: Error {
  case malformed
  /// An encoding the preview doesn't decode, by name.
  case unsupportedEncoding(String)
}

/// One leaf column: its schema path and the levels its values nest in.
nonisolated struct ParquetLeafColumn {
  let node: ParquetSchemaNode
  /// The repetition of each node from the schema's root (required) to the leaf.
  let repetitionPath: [ParquetRepetition]
  let maxDefinition: Int
  let maxRepetition: Int

  /// The leaf at the end of `chain`, the nodes from a top-level field down.
  init?(chain: [ParquetSchemaNode]) {
    guard let leaf = chain.last, leaf.physicalType != nil else { return nil }
    node = leaf
    repetitionPath = [.required] + chain.map(\.repetition)
    maxDefinition = chain.count(where: { $0.repetition != .required })
    maxRepetition = chain.count(where: { $0.repetition == .repeated })
  }

  var converter: ParquetConverter {
    ParquetConverter(
      type: node.physicalType ?? .byteArray, meaning: node.meaning, typeLength: node.typeLength)
  }
}

/// Reads a column chunk's pages: dictionary, data pages v1 and v2, decompressed and decoded.
nonisolated struct ParquetPageReader {
  static let encodingNames = [
    "PLAIN", "GROUP_VAR_INT", "PLAIN_DICTIONARY", "RLE", "BIT_PACKED", "DELTA_BINARY_PACKED",
    "DELTA_LENGTH_BYTE_ARRAY", "DELTA_BYTE_ARRAY", "RLE_DICTIONARY", "BYTE_STREAM_SPLIT",
  ]
  /// The most a page may decompress to.
  static let maxPageBytes = 64 * 1024 * 1024

  let file: [UInt8]
  let chunk: ParquetColumnChunk
  let column: ParquetLeafColumn

  /// The chunk's levels and values, until `rows` rows are complete or the chunk ends.
  func read(rows: Int) throws(ParquetPageFailure) -> ParquetLeafData {
    let start = Int(clamping: chunk.start)
    let end = start + Int(clamping: chunk.compressedSize)
    guard start >= 4, chunk.compressedSize >= 0, end <= file.count else { throw .malformed }
    var data = ParquetLeafData()
    var dictionary: [ParquetValue] = []
    var position = start
    var valuesRead = 0
    while position < end, Int64(valuesRead) < chunk.valueCount, !complete(data, rows: rows) {
      var reader = ThriftReader(bytes: file, position: position)
      let header: ThriftStruct
      do {
        header = try reader.readStruct()
      } catch {
        throw .malformed
      }
      guard let size = header.int(3).map({ Int(clamping: $0) }), size >= 0,
        size <= end - reader.position
      else { throw .malformed }
      let page = file[reader.position..<(reader.position + size)]
      position = reader.position + size
      switch header.int(1) ?? -1 {
      case 2:
        dictionary = try dictionaryPage(page, header: header)
      case 0, 3:
        let count = try dataPage(page, header: header, dictionary: dictionary, into: &data)
        valuesRead += count
      default:
        continue
      }
    }
    return data
  }

  /// Whether the levels read hold `rows` complete rows: past them for repeated columns, whose
  /// last row may go on in the next page.
  private func complete(_ data: ParquetLeafData, rows: Int) -> Bool {
    if column.maxRepetition == 0 {
      return max(data.definitions.count, data.values.count) >= rows
    }
    return data.repetitions.count(where: { $0 == 0 }) > rows
  }

  private func dictionaryPage(_ page: ArraySlice<UInt8>, header: ThriftStruct)
    throws(ParquetPageFailure) -> [ParquetValue]
  {
    guard let dictionary = header.structure(7), let count = dictionary.int(1) else {
      throw .malformed
    }
    let body = try decompress(page, size: header.int(2))
    var cursor = ParquetCursor(body)
    return try plain(&cursor, count: Int(clamping: count))
  }

  /// Decodes a data page into `data`, returning how many values (nulls included) it held.
  private func dataPage(
    _ page: ArraySlice<UInt8>, header: ThriftStruct, dictionary: [ParquetValue],
    into data: inout ParquetLeafData
  ) throws(ParquetPageFailure) -> Int {
    let levels: PageLevels
    if let first = header.structure(5) {
      levels = try pageV1(page, header: header, page: first)
    } else if let second = header.structure(8) {
      levels = try pageV2(page, header: header, page: second)
    } else {
      throw .malformed
    }
    let present =
      column.maxDefinition > 0
      ? levels.definitions.count(where: { $0 == column.maxDefinition }) : levels.count
    let values = try decodeValues(
      levels.values, encoding: levels.encoding, count: present, dictionary: dictionary)
    data.definitions += levels.definitions
    data.repetitions += levels.repetitions
    data.values += values
    return levels.count
  }

  /// A data page's levels, and its values' encoding and bytes.
  private struct PageLevels {
    let count: Int
    let encoding: Int64
    let definitions: [Int]
    let repetitions: [Int]
    let values: ArraySlice<UInt8>
  }

  private func pageV1(_ bytes: ArraySlice<UInt8>, header: ThriftStruct, page: ThriftStruct)
    throws(ParquetPageFailure) -> PageLevels
  {
    let count = try valueCount(page.int(1))
    let body = try decompress(bytes, size: header.int(2))
    var cursor = ParquetCursor(body)
    // Each level run is prefixed with its length; only the RLE hybrid is read.
    let repetitions = try prefixedLevels(&cursor, max: column.maxRepetition, count: count)
    let definitions = try prefixedLevels(&cursor, max: column.maxDefinition, count: count)
    return PageLevels(
      count: count, encoding: page.int(2) ?? -1, definitions: definitions,
      repetitions: repetitions, values: cursor.rest)
  }

  private func pageV2(_ bytes: ArraySlice<UInt8>, header: ThriftStruct, page: ThriftStruct)
    throws(ParquetPageFailure) -> PageLevels
  {
    let count = try valueCount(page.int(1))
    var cursor = ParquetCursor(bytes)
    let repetitionBytes: ArraySlice<UInt8>
    let definitionBytes: ArraySlice<UInt8>
    do {
      repetitionBytes = try cursor.take(Int(clamping: page.int(6) ?? 0))
      definitionBytes = try cursor.take(Int(clamping: page.int(5) ?? 0))
    } catch {
      throw .malformed
    }
    let repetitions = try levels(repetitionBytes, max: column.maxRepetition, count: count)
    let definitions = try levels(definitionBytes, max: column.maxDefinition, count: count)
    let levelBytes = Int64(repetitionBytes.count + definitionBytes.count)
    // The levels are never compressed; the values are unless the page says otherwise.
    let values: ArraySlice<UInt8>
    if !page.flag(7, default: true) {
      values = cursor.rest
    } else {
      values = try decompress(cursor.rest, size: header.int(2).map { $0 - levelBytes })
    }
    return PageLevels(
      count: count, encoding: page.int(4) ?? -1, definitions: definitions,
      repetitions: repetitions, values: values)
  }

  /// Levels up to `max` in the RLE hybrid, without a length prefix.
  private func levels(_ bytes: ArraySlice<UInt8>, max: Int, count: Int)
    throws(ParquetPageFailure) -> [Int]
  {
    guard max > 0 else { return [] }
    do {
      return try ParquetEncodings.hybrid(bytes, bitWidth: Self.bitWidth(max), count: count)
    } catch {
      throw .malformed
    }
  }

  /// A page's value count, which can't pass the chunk's (the budget checked that).
  private func valueCount(_ count: Int64?) throws(ParquetPageFailure) -> Int {
    guard let count, count >= 0, count <= chunk.valueCount else { throw .malformed }
    return Int(count)
  }

  private func prefixedLevels(_ cursor: inout ParquetCursor, max: Int, count: Int)
    throws(ParquetPageFailure) -> [Int]
  {
    guard max > 0 else { return [] }
    let bytes: ArraySlice<UInt8>
    do {
      bytes = try cursor.take(Int(try cursor.number(bytes: 4)))
    } catch {
      throw .malformed
    }
    return try levels(bytes, max: max, count: count)
  }

  /// Bits that hold every level up to `max`.
  static func bitWidth(_ max: Int) -> Int {
    max > 0 ? Int.bitWidth - max.leadingZeroBitCount : 0
  }

  private func decompress(_ page: ArraySlice<UInt8>, size: Int64?) throws(ParquetPageFailure)
    -> ArraySlice<UInt8>
  {
    guard let size, size >= 0, size <= Self.maxPageBytes else { throw .malformed }
    let output: [UInt8]
    do {
      switch chunk.codec {
      case 0: return page
      case 1: output = try Snappy.decompress(page, limit: Int(size))
      case 2: output = try Decompression.gunzip(page, limit: Int(size))
      default: throw ParquetPageFailure.malformed
      }
    } catch {
      throw .malformed
    }
    guard output.count == Int(size) else { throw .malformed }
    return output[...]
  }
}
