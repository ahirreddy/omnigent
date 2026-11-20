/// A page Parquet's encodings can't decode: malformed, or past its own bounds.
nonisolated struct ParquetMalformed: Error {}

/// Reads little-endian numbers and varints from a page's bytes.
nonisolated struct ParquetCursor {
  let bytes: ArraySlice<UInt8>
  private(set) var position: Int

  init(_ bytes: ArraySlice<UInt8>) {
    self.bytes = bytes
    position = bytes.startIndex
  }

  var remaining: Int { bytes.endIndex - position }
  var rest: ArraySlice<UInt8> { bytes[position...] }

  mutating func take(_ count: Int) throws(ParquetMalformed) -> ArraySlice<UInt8> {
    guard count >= 0, count <= remaining else { throw ParquetMalformed() }
    defer { position += count }
    return bytes[position..<(position + count)]
  }

  /// A little-endian unsigned number of `count` bytes (at most eight).
  mutating func number(bytes count: Int) throws(ParquetMalformed) -> UInt64 {
    try take(count).reversed().reduce(into: UInt64(0)) { $0 = $0 << 8 | UInt64($1) }
  }

  mutating func varint() throws(ParquetMalformed) -> UInt64 {
    var value: UInt64 = 0
    for shift in stride(from: UInt64(0), to: 64, by: 7) {
      let next = try take(1).first ?? 0
      value |= UInt64(next & 0x7F) << shift
      if next & 0x80 == 0 { return value }
    }
    throw ParquetMalformed()
  }

  mutating func zigzag() throws(ParquetMalformed) -> Int64 {
    let value = try varint()
    return Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
  }
}

/// Parquet's value and level encodings.
nonisolated enum ParquetEncodings {
  /// The RLE and bit-packed hybrid (levels, dictionary indices and booleans).
  /// - Parameters:
  ///   - bytes: The encoded runs, without a length prefix.
  ///   - bitWidth: Bits per value.
  ///   - count: Values to read.
  /// - Returns: The values.
  /// - Throws: ``ParquetMalformed`` when the runs end early.
  static func hybrid(_ bytes: ArraySlice<UInt8>, bitWidth: Int, count: Int) throws(ParquetMalformed)
    -> [Int]
  {
    guard (0...32).contains(bitWidth) else { throw ParquetMalformed() }
    var cursor = ParquetCursor(bytes)
    var values: [Int] = []
    values.reserveCapacity(count)
    while values.count < count {
      let header = try cursor.varint()
      let left = count - values.count
      if header & 1 == 1 {
        let groups = Int(clamping: header >> 1)
        let packed = try cursor.take(
          min(min(groups, cursor.remaining) * bitWidth, cursor.remaining))
        values += unpack(
          packed, bitWidth: bitWidth, count: groups >= left ? left : min(groups * 8, left))
      } else {
        let run = Int(clamping: header >> 1)
        let value = Int(try cursor.number(bytes: (bitWidth + 7) / 8))
        values += repeatElement(value, count: min(run, left))
      }
    }
    return values
  }

  /// `count` values of `bitWidth` bits, packed from the lowest bit up.
  static func unpack(_ bytes: ArraySlice<UInt8>, bitWidth: Int, count: Int) -> [Int] {
    guard bitWidth > 0 else { return Array(repeating: 0, count: count) }
    var values: [Int] = []
    values.reserveCapacity(count)
    var bit = 0
    let mask = (1 << bitWidth) - 1
    for _ in 0..<count {
      var value = 0
      var taken = 0
      while taken < bitWidth {
        let index = bytes.startIndex + (bit + taken) / 8
        guard index < bytes.endIndex else { break }
        let offset = (bit + taken) % 8
        let available = min(8 - offset, bitWidth - taken)
        value |= (Int(bytes[index]) >> offset & ((1 << available) - 1)) << taken
        taken += available
      }
      values.append(value & mask)
      bit += bitWidth
    }
    return values
  }

  /// `DELTA_BINARY_PACKED` integers, and where they end.
  static func deltaBinaryPacked(_ cursor: inout ParquetCursor) throws(ParquetMalformed) -> [Int64] {
    let blockSize = Int(clamping: try cursor.varint())
    let miniblocks = Int(clamping: try cursor.varint())
    let total = Int(clamping: try cursor.varint())
    var value = try cursor.zigzag()
    guard miniblocks > 0, blockSize > 0, blockSize.isMultiple(of: miniblocks), total <= 1 << 30
    else { throw ParquetMalformed() }
    let perMiniblock = blockSize / miniblocks
    var values: [Int64] = total > 0 ? [value] : []
    while values.count < total {
      let minDelta = try cursor.zigzag()
      let widths = try cursor.take(miniblocks)
      for width in widths {
        // Miniblocks past the last value store no data, only their width.
        guard values.count < total else { break }
        guard width <= 64 else { throw ParquetMalformed() }
        let packed = try cursor.take(perMiniblock * Int(width) / 8)
        for delta in unpack64(packed, bitWidth: Int(width), count: perMiniblock)
        where values.count < total {
          value = value &+ minDelta &+ Int64(bitPattern: delta)
          values.append(value)
        }
      }
    }
    return values
  }

  /// Like ``unpack(_:bitWidth:count:)`` for widths up to 64 bits.
  private static func unpack64(_ bytes: ArraySlice<UInt8>, bitWidth: Int, count: Int) -> [UInt64] {
    guard bitWidth > 0 else { return Array(repeating: 0, count: count) }
    var values: [UInt64] = []
    values.reserveCapacity(count)
    var bit = 0
    for _ in 0..<count {
      var value: UInt64 = 0
      for offset in 0..<min(bitWidth, 64) {
        let index = bytes.startIndex + (bit + offset) / 8
        guard index < bytes.endIndex else { break }
        let set = UInt64(bytes[index] >> UInt8((bit + offset) % 8)) & 1
        value |= set << UInt64(offset)
      }
      values.append(value)
      bit += bitWidth
    }
    return values
  }

  /// `DELTA_LENGTH_BYTE_ARRAY` values: their lengths, then their bytes back to back.
  static func deltaLengthByteArray(_ cursor: inout ParquetCursor) throws(ParquetMalformed)
    -> [ArraySlice<UInt8>]
  {
    let lengths = try deltaBinaryPacked(&cursor)
    var values: [ArraySlice<UInt8>] = []
    values.reserveCapacity(lengths.count)
    for length in lengths { values.append(try cursor.take(Int(clamping: length))) }
    return values
  }

  /// `DELTA_BYTE_ARRAY` values: each shares a prefix with the one before it.
  static func deltaByteArray(_ cursor: inout ParquetCursor) throws(ParquetMalformed)
    -> [ArraySlice<UInt8>]
  {
    let prefixes = try deltaBinaryPacked(&cursor)
    let suffixes = try deltaLengthByteArray(&cursor)
    guard prefixes.count == suffixes.count else { throw ParquetMalformed() }
    var previous: [UInt8] = []
    var values: [ArraySlice<UInt8>] = []
    values.reserveCapacity(suffixes.count)
    for (prefix, suffix) in zip(prefixes, suffixes) {
      guard prefix >= 0, prefix <= previous.count else { throw ParquetMalformed() }
      previous = Array(previous.prefix(Int(prefix))) + suffix
      values.append(previous[...])
    }
    return values
  }

  /// `BYTE_STREAM_SPLIT` values of `width` bytes: byte `k` of every value, then byte `k + 1`.
  static func byteStreamSplit(_ bytes: ArraySlice<UInt8>, width: Int, count: Int)
    throws(ParquetMalformed) -> [ArraySlice<UInt8>]
  {
    guard width > 0, width * count <= bytes.count else { throw ParquetMalformed() }
    let base = bytes.startIndex
    return (0..<count).map { index in
      ArraySlice((0..<width).map { stream in bytes[base + stream * count + index] })
    }
  }
}
