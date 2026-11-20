/// A Parquet value as the web's reader (hyparquet) gives it, before it is shown as text.
nonisolated enum ParquetValue {
  /// No value at all: a struct member or map value that wasn't there (JavaScript's
  /// `undefined`), left out of an object's JSON.
  case missing
  case null
  case bool(Bool)
  /// A JavaScript number: 32-bit integers, floats, doubles and decimals.
  case number(Double)
  /// A 64-bit integer (a JavaScript `bigint`), written exactly and quoted in JSON.
  case bigInt(Int64)
  case bigUnsigned(UInt64)
  case text(String)
  /// Bytes that aren't text, shown by their count.
  case bytes(Int)
  /// A date or timestamp, in milliseconds since 1970; `nil` past what a JavaScript date holds.
  case date(millis: Int64?)
  case list([Self])
  case object([ParquetField])

  /// The largest time a JavaScript date holds, either side of 1970.
  static let maxDateMillis: Int64 = 8_640_000_000_000_000

  /// A date of `millis`, or an out-of-range one.
  static func date(_ millis: Int64?) -> Self {
    .date(millis: millis.flatMap { abs($0) <= maxDateMillis ? $0 : nil })
  }
}

/// A struct member.
nonisolated struct ParquetField {
  let name: String
  let value: ParquetValue
}

/// Parquet values as the table shows them (web `parquetCellText`).
nonisolated enum ParquetText {
  /// What a nested column shows when its values are past the preview's decoding limit.
  static let skippedNested = "(too many values to preview)"

  /// `value` as a cell shows it, for example `2026-03-01` for a date column.
  /// - Parameters:
  ///   - value: The value.
  ///   - isDate: The column is a `DATE`, which shows no time.
  ///   - limit: The most characters to build for a nested value; past it the text is cut and
  ///     ends in `…`.
  /// - Returns: The text.
  static func cell(_ value: ParquetValue, isDate: Bool, limit: Int = .max) -> String {
    switch value {
    case .missing, .null: return ""
    case .bool(let flag): return flag ? "true" : "false"
    case .number(let number): return SpreadsheetText.number(number)
    case .bigInt(let integer): return String(integer)
    case .bigUnsigned(let integer): return String(integer)
    case .text(let text): return text
    case .bytes(let count): return "(\(count) bytes)"
    case .date(let millis): return dateText(millis, isDate: isDate)
    case .list, .object: return json(value, limit: limit)
    }
  }

  /// A date as an ISO date, or a date and time; a time at midnight shows as its date.
  private static func dateText(_ millis: Int64?, isDate: Bool) -> String {
    guard let millis else { return "(out-of-range date)" }
    let iso = isoText(millis)
    if isDate || iso.hasSuffix("T00:00:00.000Z") {
      return String(iso.prefix(while: { $0 != "T" }))
    }
    return iso.replacing(".000Z", with: "Z")
  }

  /// A nested value as JSON, cut at `limit` and ending in `…` past it.
  private static func json(_ value: ParquetValue, limit: Int) -> String {
    var writer = JSONText(limit: limit)
    do {
      try writer.write(value)
      return writer.text
    } catch {
      return SpreadsheetText.prefix(writer.text, utf16Count: limit) + "\u{2026}"
    }
  }

  /// `toISOString`'s text, for example `2026-03-01T12:00:00.000Z`.
  static func isoText(_ millis: Int64) -> String {
    let (date, time) = SpreadsheetText.civil(millis)
    return "\(date)T\(time.textWithMillis)Z"
  }
}

/// A nested value as JSON (web `boundedJson`), stopping once the text passes its limit: a
/// list repeating one long string can describe far more text than the file holds.
nonisolated struct JSONText {
  struct PastLimit: Error {}

  let limit: Int
  private(set) var text = ""
  private var length = 0

  init(limit: Int) {
    self.limit = limit
  }

  // swiftlint:disable:next cyclomatic_complexity
  mutating func write(_ value: ParquetValue) throws(PastLimit) {
    switch value {
    case .missing, .null: try emit("null")
    case .bool(let flag): try emit(flag ? "true" : "false")
    case .number(let number): try emit(number.isFinite ? SpreadsheetText.number(number) : "null")
    case .bigInt(let integer): try emit("\"\(integer)\"")
    case .bigUnsigned(let integer): try emit("\"\(integer)\"")
    // A long string is cut before it is quoted, so it isn't copied whole.
    case .text(let string):
      try emit(
        Self.quoted(SpreadsheetText.prefix(string, utf16Count: limit < .max ? limit + 1 : limit)))
    case .bytes(let count): try emit("\"(\(count) bytes)\"")
    case .date(let millis): try emit(millis.map { "\"\(ParquetText.isoText($0))\"" } ?? "null")
    case .list(let items):
      try emit("[")
      for (index, item) in items.enumerated() {
        if index > 0 { try emit(",") }
        try write(item)
      }
      try emit("]")
    case .object(let fields):
      try emit("{")
      var first = true
      for field in fields {
        if case .missing = field.value { continue }
        try emit("\(first ? "" : ",")\(Self.quoted(field.name)):")
        first = false
        try write(field.value)
      }
      try emit("}")
    }
  }

  private mutating func emit(_ piece: String) throws(PastLimit) {
    text += piece
    length += piece.utf16.count
    if length > limit { throw PastLimit() }
  }

  /// `JSON.stringify` of a string.
  static func quoted(_ string: String) -> String {
    var quoted = "\""
    for scalar in string.unicodeScalars {
      switch scalar {
      case "\"": quoted += "\\\""
      case "\\": quoted += "\\\\"
      case "\n": quoted += "\\n"
      case "\r": quoted += "\\r"
      case "\t": quoted += "\\t"
      case "\u{08}": quoted += "\\b"
      case "\u{0C}": quoted += "\\f"
      case let control where control.value < 0x20:
        quoted += "\\u" + SpreadsheetText.pad(Int64(control.value), 4, hex: true)
      default: quoted.unicodeScalars.append(scalar)
      }
    }
    return quoted + "\""
  }
}
