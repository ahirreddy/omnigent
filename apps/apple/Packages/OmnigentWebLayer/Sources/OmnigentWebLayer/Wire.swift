internal import Foundation
internal import OWLProtocol

/// Builds an OWL payload: a sequence of tagged fields (owl_protocol.h). Little-endian.
nonisolated struct WireEncoder: Sendable {
  private(set) var bytes: [UInt8] = []

  func u64(_ tag: OWLField, _ value: UInt64) -> Self {
    appending(tag, .uInt64, value.littleEndianBytes)
  }

  func i64(_ tag: OWLField, _ value: Int64) -> Self {
    appending(tag, .int64, UInt64(bitPattern: value).littleEndianBytes)
  }

  func double(_ tag: OWLField, _ value: Double) -> Self {
    appending(tag, .double, value.bitPattern.littleEndianBytes)
  }

  func bool(_ tag: OWLField, _ value: Bool) -> Self {
    appending(tag, .bool, [value ? 1 : 0])
  }

  func string(_ tag: OWLField, _ value: String) -> Self {
    appending(tag, .string, Array(value.utf8))
  }

  func bytes(_ tag: OWLField, _ value: [UInt8]) -> Self {
    appending(tag, .bytes, value)
  }

  private func appending(_ tag: OWLField, _ type: OWLFieldType, _ value: [UInt8]) -> Self {
    var copy = self
    copy.bytes += tag.rawValue.littleEndianBytes
    copy.bytes.append(type.rawValue)
    copy.bytes.append(0)
    copy.bytes += UInt32(value.count).littleEndianBytes
    copy.bytes += value
    return copy
  }
}

/// Reads an OWL payload. Unknown tags are kept but ignored by callers (forward compatibility).
nonisolated struct WireDecoder: Sendable {
  private struct Field: Sendable {
    let type: UInt8
    let range: Range<Int>
  }

  private let bytes: [UInt8]
  private let fields: [UInt16: Field]

  /// - Throws: `WebLayerError.channelFailed` when a field runs past the payload.
  init(_ bytes: [UInt8]) throws(WebLayerError) {
    var fields: [UInt16: Field] = [:]
    var offset = 0
    while offset < bytes.count {
      guard bytes.count - offset >= 8 else {
        throw .channelFailed("Truncated field header at offset \(offset).")
      }
      let tag = UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
      let type = bytes[offset + 2]
      let length = Int(Self.readU32(bytes, at: offset + 4))
      offset += 8
      guard bytes.count - offset >= length else {
        throw .channelFailed("Field \(tag) claims \(length) bytes past the payload.")
      }
      fields[tag] = Field(type: type, range: offset..<(offset + length))
      offset += length
    }
    self.bytes = bytes
    self.fields = fields
  }

  func u64(_ tag: OWLField) -> UInt64? {
    scalar(tag, .uInt64).map { Self.readU64($0) }
  }

  func i64(_ tag: OWLField) -> Int64? {
    u64Bits(tag, .int64).map { Int64(bitPattern: $0) }
  }

  func double(_ tag: OWLField) -> Double? {
    u64Bits(tag, .double).map { Double(bitPattern: $0) }
  }

  /// A boolean field, or `missing` when the field is absent or has another type.
  func bool(_ tag: OWLField, missing: Bool = false) -> Bool {
    guard let field = fields[tag.rawValue], field.type == OWLFieldType.bool.rawValue,
      field.range.count == 1
    else {
      return missing
    }
    return bytes[field.range.lowerBound] != 0
  }

  func string(_ tag: OWLField) -> String? {
    guard let field = fields[tag.rawValue], field.type == OWLFieldType.string.rawValue else {
      return nil
    }
    // Invalid UTF-8 reads as a missing field.
    return String(bytes: bytes[field.range], encoding: .utf8)
  }

  func data(_ tag: OWLField) -> Data? {
    guard let field = fields[tag.rawValue], field.type == OWLFieldType.bytes.rawValue else {
      return nil
    }
    return Data(bytes[field.range])
  }

  /// A required field, or a typed error naming the message and field.
  func require<T>(_ value: T?, _ tag: OWLField, in kind: OWLMessageKind) throws(WebLayerError)
    -> T
  {
    guard let value else {
      throw .channelFailed("Message \(kind.rawValue) lacks required field \(tag.rawValue).")
    }
    return value
  }

  private func scalar(_ tag: OWLField, _ type: OWLFieldType) -> ArraySlice<UInt8>? {
    guard let field = fields[tag.rawValue], field.type == type.rawValue, field.range.count == 8
    else {
      return nil
    }
    return bytes[field.range]
  }

  private func u64Bits(_ tag: OWLField, _ type: OWLFieldType) -> UInt64? {
    scalar(tag, type).map { Self.readU64($0) }
  }

  private static func readU64(_ slice: ArraySlice<UInt8>) -> UInt64 {
    var value: UInt64 = 0
    for (shift, byte) in slice.enumerated() {
      value |= UInt64(byte) << (8 * UInt64(shift))
    }
    return value
  }

  private static func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    var value: UInt32 = 0
    for index in 0..<4 {
      value |= UInt32(bytes[offset + index]) << (8 * UInt32(index))
    }
    return value
  }
}

extension FixedWidthInteger {
  fileprivate nonisolated var littleEndianBytes: [UInt8] {
    (0..<(Self.bitWidth / 8)).map { UInt8(truncatingIfNeeded: self >> ($0 * 8)) }
  }
}
