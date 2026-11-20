/// Malformed or unsupported Thrift data.
nonisolated struct ThriftMalformed: Error {}

/// A value read with Thrift's compact protocol, which Parquet's footer and page headers use.
nonisolated enum ThriftValue {
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case binary(ArraySlice<UInt8>)
  case list([Self])
  case structure(ThriftStruct)
  /// A map's entries; Parquet's structures read here hold none, so only their count is kept.
  case map(Int)
}

/// A Thrift struct's fields by id.
nonisolated struct ThriftStruct {
  var fields: [Int16: ThriftValue] = [:]

  func int(_ id: Int16) -> Int64? {
    if case .int(let value) = fields[id] { value } else { nil }
  }

  /// A boolean field, or `fallback` when it isn't set.
  func flag(_ id: Int16, default fallback: Bool) -> Bool {
    if case .bool(let value) = fields[id] { value } else { fallback }
  }

  func string(_ id: Int16) -> String? {
    if case .binary(let bytes) = fields[id] { SpreadsheetText.utf8(bytes) } else { nil }
  }

  func structure(_ id: Int16) -> Self? {
    if case .structure(let value) = fields[id] { value } else { nil }
  }

  func list(_ id: Int16) -> [ThriftValue] {
    if case .list(let values) = fields[id] { values } else { [] }
  }

  func structures(_ id: Int16) -> [Self] {
    list(id).compactMap { if case .structure(let value) = $0 { value } else { nil } }
  }

  /// The id of a union's set field, for example a logical type's.
  var unionField: Int16? { fields.keys.min() }
}

/// Reads Thrift compact-protocol structs from bytes.
nonisolated struct ThriftReader {
  private let bytes: [UInt8]
  /// Where the next value starts.
  private(set) var position: Int

  init(bytes: [UInt8], position: Int) {
    self.bytes = bytes
    self.position = position
  }

  /// The struct at ``position``, which moves past it.
  mutating func readStruct() throws(ThriftMalformed) -> ThriftStruct {
    try structure(depth: 0)
  }

  private mutating func structure(depth: Int) throws(ThriftMalformed) -> ThriftStruct {
    guard depth < 32 else { throw ThriftMalformed() }
    var result = ThriftStruct()
    var fieldID: Int16 = 0
    while true {
      let header = try byte()
      if header == 0 { return result }
      let delta = Int16(header >> 4)
      fieldID = delta == 0 ? Int16(truncatingIfNeeded: zigzag(try varint())) : fieldID &+ delta
      let type = header & 0x0F
      switch type {
      case 1: result.fields[fieldID] = .bool(true)
      case 2: result.fields[fieldID] = .bool(false)
      default: result.fields[fieldID] = try value(type: type, depth: depth)
      }
    }
  }

  private mutating func value(type: UInt8, depth: Int) throws(ThriftMalformed) -> ThriftValue {
    switch type {
    case 1, 2: return .bool(try byte() == 1)
    case 3: return .int(Int64(Int8(bitPattern: try byte())))
    case 4, 5, 6: return .int(zigzag(try varint()))
    case 7: return .double(Double(bitPattern: try fixed64()))
    case 8: return .binary(try binary())
    case 9, 10: return .list(try list(depth: depth))
    case 11: return .map(try skipMap(depth: depth))
    case 12: return .structure(try structure(depth: depth + 1))
    default: throw ThriftMalformed()
    }
  }

  private mutating func list(depth: Int) throws(ThriftMalformed) -> [ThriftValue] {
    let header = try byte()
    let shortCount = Int(header >> 4)
    let count = shortCount == 15 ? Int(try varint()) : shortCount
    // Every element takes at least a byte, so a count past the bytes left is malformed.
    guard count >= 0, count <= bytes.count - position else { throw ThriftMalformed() }
    var values: [ThriftValue] = []
    values.reserveCapacity(count)
    for _ in 0..<count { values.append(try value(type: header & 0x0F, depth: depth + 1)) }
    return values
  }

  private mutating func skipMap(depth: Int) throws(ThriftMalformed) -> Int {
    let count = Int(try varint())
    guard count >= 0, count <= bytes.count - position else { throw ThriftMalformed() }
    guard count > 0 else { return 0 }
    let types = try byte()
    for _ in 0..<count {
      _ = try value(type: types >> 4, depth: depth + 1)
      _ = try value(type: types & 0x0F, depth: depth + 1)
    }
    return count
  }

  private mutating func binary() throws(ThriftMalformed) -> ArraySlice<UInt8> {
    let length = try varint()
    guard length <= UInt64(bytes.count - position) else { throw ThriftMalformed() }
    let end = position + Int(length)
    defer { position = end }
    return bytes[position..<end]
  }

  private mutating func byte() throws(ThriftMalformed) -> UInt8 {
    guard position < bytes.count else { throw ThriftMalformed() }
    defer { position += 1 }
    return bytes[position]
  }

  private mutating func varint() throws(ThriftMalformed) -> UInt64 {
    var value: UInt64 = 0
    for shift in stride(from: UInt64(0), to: 64, by: 7) {
      let next = try byte()
      value |= UInt64(next & 0x7F) << shift
      if next & 0x80 == 0 { return value }
    }
    throw ThriftMalformed()
  }

  private mutating func fixed64() throws(ThriftMalformed) -> UInt64 {
    var value: UInt64 = 0
    for index in 0..<8 { value |= UInt64(try byte()) << (8 * UInt64(index)) }
    return value
  }

  private func zigzag(_ value: UInt64) -> Int64 {
    Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
  }
}
