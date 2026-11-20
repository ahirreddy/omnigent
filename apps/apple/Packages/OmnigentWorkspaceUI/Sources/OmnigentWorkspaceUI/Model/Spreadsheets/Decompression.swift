import Compression

/// Why a deflate stream wasn't inflated.
nonisolated enum DecompressionFailure: Error {
  /// It inflates past the limit it was given.
  case tooLarge
  /// Its gzip or zlib header is missing or broken.
  case malformed
}

/// The decompressors the spreadsheet readers use: raw deflate (zip parts), gzip and Snappy
/// (Parquet pages).
nonisolated enum Decompression {
  /// The output of the raw deflate stream `input`, at most `limit` bytes.
  /// - Parameters:
  ///   - input: The deflate stream; anything after its end is ignored.
  ///   - limit: The most bytes it may inflate to.
  ///   - expected: The size the container declares, where to start the output buffer.
  /// - Returns: The inflated bytes.
  /// - Throws: ``DecompressionFailure/tooLarge`` past `limit`.
  static func inflate(_ input: ArraySlice<UInt8>, limit: Int, expected: Int = 0)
    throws(DecompressionFailure) -> [UInt8]
  {
    guard limit >= 0 else { throw .tooLarge }
    guard !input.isEmpty else { return [] }
    // A declared size can understate; the buffer grows until the output fits or passes the limit.
    var capacity = min(max(expected, 64 * 1024), limit) + 1
    while true {
      var output = [UInt8](repeating: 0, count: capacity)
      let written = decode(input, into: &output)
      if written < capacity {
        output.removeSubrange(written...)
        return output
      }
      guard capacity <= limit else { throw .tooLarge }
      capacity = min(capacity * 4, limit + 1)
    }
  }

  /// A gzip member's (or zlib stream's) inflated bytes, at most `limit`.
  /// - Parameters:
  ///   - input: The compressed bytes.
  ///   - limit: The most bytes it may inflate to.
  /// - Returns: The inflated bytes.
  /// - Throws: ``DecompressionFailure`` past `limit` or without a gzip or zlib header.
  static func gunzip(_ input: ArraySlice<UInt8>, limit: Int) throws(DecompressionFailure)
    -> [UInt8]
  {
    guard let start = deflateStart(input) else { throw .malformed }
    return try inflate(input[start...], limit: limit, expected: limit)
  }

  /// Where the deflate stream starts after a gzip or zlib header.
  private static func deflateStart(_ input: ArraySlice<UInt8>) -> Int? {
    let base = input.startIndex
    let byte = { (offset: Int) -> Int? in
      input.indices.contains(base + offset) ? Int(input[base + offset]) : nil
    }
    // zlib: a deflate method byte whose header checksums.
    if let first = byte(0), let second = byte(1), first & 0x0F == 8,
      (first << 8 | second).isMultiple(of: 31)
    {
      return base + 2
    }
    guard byte(0) == 0x1F, byte(1) == 0x8B, byte(2) == 8, let flags = byte(3) else { return nil }
    var offset = 10
    if flags & 0x04 != 0 {
      guard let low = byte(offset), let high = byte(offset + 1) else { return nil }
      offset += 2 + (low | high << 8)
    }
    // The name and the comment end in a zero byte.
    for flag in [0x08, 0x10] where flags & flag != 0 {
      while let value = byte(offset), value != 0 { offset += 1 }
      offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 }
    return base + offset <= input.endIndex ? base + offset : nil
  }

  /// Inflates `input` into `output`, returning the bytes written (all of `output` when the
  /// stream holds more).
  private static func decode(_ input: ArraySlice<UInt8>, into output: inout [UInt8]) -> Int {
    output.withUnsafeMutableBufferPointer { destination in
      input.withUnsafeBufferPointer { source in
        guard let target = destination.baseAddress, let origin = source.baseAddress else {
          return 0
        }
        return unsafe compression_decode_buffer(
          target, destination.count, origin, source.count, nil, COMPRESSION_ZLIB)
      }
    }
  }
}

/// A Snappy block's bytes (the raw format Parquet pages use).
nonisolated enum Snappy {
  /// A malformed block.
  struct Malformed: Error {}

  /// The block `input` decompressed.
  /// - Parameters:
  ///   - input: The block.
  ///   - limit: The most bytes it may hold.
  /// - Returns: The bytes.
  /// - Throws: ``Malformed`` for a broken block or one past `limit`.
  static func decompress(_ input: ArraySlice<UInt8>, limit: Int) throws(Malformed) -> [UInt8] {
    var reader = SnappyCursor(input: input)
    let length = try reader.varint()
    guard length <= limit else { throw Malformed() }
    var output: [UInt8] = []
    output.reserveCapacity(length)
    while !reader.atEnd {
      let tag = Int(try reader.byte())
      if tag & 3 == 0 {
        try reader.literal(tag: tag, into: &output)
      } else {
        let (count, offset) = try reader.copy(tag: tag)
        guard offset > 0, offset <= output.count, output.count + count <= length else {
          throw Malformed()
        }
        // A copy may overlap what it writes, so bytes go one at a time.
        let start = output.count - offset
        for index in 0..<count { output.append(output[start + index]) }
      }
      guard output.count <= length else { throw Malformed() }
    }
    guard output.count == length else { throw Malformed() }
    return output
  }
}

/// Reads a Snappy block's elements.
nonisolated private struct SnappyCursor {
  let input: ArraySlice<UInt8>
  var position: Int

  init(input: ArraySlice<UInt8>) {
    self.input = input
    position = input.startIndex
  }

  var atEnd: Bool { position >= input.endIndex }

  mutating func byte() throws(Snappy.Malformed) -> UInt8 {
    guard position < input.endIndex else { throw Snappy.Malformed() }
    defer { position += 1 }
    return input[position]
  }

  mutating func varint() throws(Snappy.Malformed) -> Int {
    var value = 0
    for shift in stride(from: 0, to: 35, by: 7) {
      let next = try byte()
      value |= Int(next & 0x7F) << shift
      if next & 0x80 == 0 { return value }
    }
    throw Snappy.Malformed()
  }

  /// A little-endian number of `count` bytes.
  mutating func number(bytes count: Int) throws(Snappy.Malformed) -> Int {
    var value = 0
    for index in 0..<count { value |= Int(try byte()) << (8 * index) }
    return value
  }

  mutating func literal(tag: Int, into output: inout [UInt8]) throws(Snappy.Malformed) {
    var length = tag >> 2
    if length >= 60 { length = try number(bytes: length - 59) }
    length += 1
    guard length <= input.endIndex - position else { throw Snappy.Malformed() }
    output.append(contentsOf: input[position..<(position + length)])
    position += length
  }

  /// A copy's length and how far back it starts.
  mutating func copy(tag: Int) throws(Snappy.Malformed) -> (Int, Int) {
    switch tag & 3 {
    case 1:
      let length = 4 + ((tag >> 2) & 7)
      return (length, (tag >> 5) << 8 | Int(try byte()))
    case 2:
      return ((tag >> 2) + 1, try number(bytes: 2))
    default:
      return ((tag >> 2) + 1, try number(bytes: 4))
    }
  }
}
