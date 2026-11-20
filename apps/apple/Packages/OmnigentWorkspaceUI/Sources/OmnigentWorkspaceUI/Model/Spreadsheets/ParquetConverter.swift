import Foundation

/// Turns a column's physical values into what the table shows, as hyparquet converts them with
/// `utf8: false`: dates and timestamps as dates, decimals scaled, 64-bit integers exact, text
/// only where the schema says so, and other bytes by their count.
nonisolated struct ParquetConverter {
  let type: ParquetPhysicalType
  let meaning: ParquetMeaning
  let typeLength: Int

  private static let dayMillis = SpreadsheetText.dayMillis
  /// The Julian day of 1970-01-01, for `INT96` timestamps.
  private static let unixJulianDay: Int64 = 2_440_588

  func value(_ raw: Int32) -> ParquetValue {
    switch meaning {
    case .date:
      let (millis, overflow) = Int64(raw).multipliedReportingOverflow(by: Self.dayMillis)
      return .date(overflow ? nil : millis)
    case .decimal(let scale): return .number(Double(raw) * pow(10, -Double(scale)))
    case .unsigned: return .number(Double(UInt32(bitPattern: raw)))
    default: return .number(Double(raw))
    }
  }

  func value(_ raw: Int64) -> ParquetValue {
    switch meaning {
    case .timestamp(let perMillisecond): return .date(raw / perMillisecond)
    case .decimal(let scale): return .number(Double(raw) * pow(10, -Double(scale)))
    case .unsigned: return .bigUnsigned(UInt64(bitPattern: raw))
    case .date:
      let (millis, overflow) = raw.multipliedReportingOverflow(by: Self.dayMillis)
      return .date(overflow ? nil : millis)
    default: return .bigInt(raw)
    }
  }

  func value(_ raw: Float) -> ParquetValue { .number(Double(raw)) }

  func value(_ raw: Double) -> ParquetValue { .number(raw) }

  func value(_ raw: Bool) -> ParquetValue { .bool(raw) }

  /// A `BYTE_ARRAY`, `FIXED_LEN_BYTE_ARRAY` or `INT96` value.
  func value(_ bytes: ArraySlice<UInt8>) -> ParquetValue {
    if type == .int96 { return int96(bytes) }
    switch meaning {
    case .string: return .text(SpreadsheetText.utf8(bytes))
    case .decimal(let scale): return .number(Self.signedBigEndian(bytes) * pow(10, -Double(scale)))
    case .uuid where bytes.count == 16: return .text(Self.uuid(bytes))
    case .float16 where bytes.count == 2: return .number(Self.half(bytes))
    default: return .bytes(bytes.count)
    }
  }

  /// Nanoseconds into the day, then the Julian day.
  private func int96(_ bytes: ArraySlice<UInt8>) -> ParquetValue {
    guard bytes.count == 12 else { return .date(nil) }
    let little = { (range: Range<Int>) in
      range.reversed().reduce(into: UInt64(0)) {
        $0 = $0 << 8 | UInt64(bytes[bytes.startIndex + $1])
      }
    }
    let nanos = Int64(bitPattern: little(0..<8))
    let day = Int64(Int32(truncatingIfNeeded: little(8..<12)))
    let (days, overflow) = (day - Self.unixJulianDay).multipliedReportingOverflow(
      by: Self.dayMillis)
    return .date(overflow ? nil : days.addingReportingOverflow(nanos / 1_000_000).partialValue)
  }

  /// A two's complement big-endian integer, as a JavaScript number (web `parseDecimal`).
  private static func signedBigEndian(_ bytes: ArraySlice<UInt8>) -> Double {
    let value = bytes.reduce(0.0) { $0 * 256 + Double($1) }
    let bits = Double(bytes.count * 8)
    return value >= pow(2, bits - 1) ? value - pow(2, bits) : value
  }

  private static func uuid(_ bytes: ArraySlice<UInt8>) -> String {
    let hex = bytes.map { SpreadsheetText.pad(Int64($0), 2, hex: true) }.joined()
    let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
      String(hex.dropFirst(range.lowerBound).prefix(range.count))
    }
    return groups.joined(separator: "-")
  }

  /// An IEEE half-precision float, little-endian.
  private static func half(_ bytes: ArraySlice<UInt8>) -> Double {
    let bits = Int(bytes[bytes.startIndex]) | Int(bytes[bytes.startIndex + 1]) << 8
    let sign = bits & 0x8000 != 0 ? -1.0 : 1.0
    let exponent = (bits >> 10) & 0x1F
    let fraction = Double(bits & 0x3FF)
    switch exponent {
    case 0: return sign * fraction * pow(2, -24)
    case 0x1F: return fraction == 0 ? sign * .infinity : .nan
    default: return sign * (1 + fraction / 1024) * pow(2, Double(exponent - 15))
    }
  }
}
