import Foundation

/// Numbers and times as the web's readers show them, so a cell reads the same in the app and in
/// the browser.
nonisolated enum SpreadsheetText {
  static let dayMillis: Int64 = 86_400_000

  /// `value` as JavaScript's `String(number)` writes it: the shortest digits that read back,
  /// in plain notation from 1e-6 up to 1e21 and in exponent notation outside.
  static func number(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
    if value == 0 { return "0" }
    let (digits, point) = shortestDigits(abs(value))
    let sign = value < 0 ? "-" : ""
    let count = digits.count
    if count <= point, point <= 21 {
      return "\(sign)\(digits)\(String(repeating: "0", count: point - count))"
    }
    if point > 0, point <= 21 {
      return "\(sign)\(digits.prefix(point)).\(digits.dropFirst(point))"
    }
    if point > -6, point <= 0 {
      return "\(sign)0.\(String(repeating: "0", count: -point))\(digits)"
    }
    let exponent = point - 1
    let mantissa = count == 1 ? digits : "\(digits.prefix(1)).\(digits.dropFirst())"
    return "\(sign)\(mantissa)e\(exponent >= 0 ? "+" : "-")\(abs(exponent))"
  }

  /// The significant digits of a positive `value` and where its decimal point falls: `1234.5`
  /// is `("12345", 4)`, `0.001` is `("1", -2)`.
  private static func shortestDigits(_ value: Double) -> (String, Int) {
    // Swift's description is the shortest form that reads back, as JavaScript's is.
    let text = "\(value)"
    let parts = text.split(separator: "e", maxSplits: 1)
    let mantissa = parts.first.map(String.init) ?? text
    let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let whole = mantissa.split(separator: ".", maxSplits: 1)
    let integer = whole.first.map(String.init) ?? ""
    let fraction = whole.count > 1 ? String(whole[1]) : ""
    var digits = integer + fraction
    var point = integer.count + exponent
    while digits.hasPrefix("0"), digits.count > 1 {
      digits.removeFirst()
      point -= 1
    }
    while digits.hasSuffix("0"), digits.count > 1 { digits.removeLast() }
    return (digits, point)
  }

  /// `bytes` as UTF-8 with any broken sequence replaced, as the web's `TextDecoder` reads them.
  static func utf8(_ bytes: some Collection<UInt8>) -> String {
    // swiftlint:disable:next optional_data_string_conversion
    String(decoding: bytes, as: UTF8.self)
  }

  /// A plain Excel number as Excel shows it by default: at most 15 significant digits.
  static func excelNumber(_ value: String) -> String {
    guard let number = Double(value.trimmingCharacters(in: .whitespaces)), number.isFinite else {
      return value
    }
    return Self.number(significant15(number))
  }

  /// `value` rounded to 15 significant digits, as JavaScript's `toPrecision(15)` rounds it.
  static func significant15(_ value: Double) -> Double {
    guard value != 0 else { return value }
    let (digits, point) = shortestDigits(abs(value))
    guard digits.count > 15 else { return value }
    var kept = digits.utf8.prefix(15).map { Int($0) - 48 }
    var exponent = point
    // Halves round up, carrying through nines.
    if digits.utf8.dropFirst(15).first.map({ Int($0) - 48 >= 5 }) == true {
      var index = kept.count - 1
      while index >= 0, kept[index] == 9 {
        kept[index] = 0
        index -= 1
      }
      if index >= 0 {
        kept[index] += 1
      } else {
        kept.insert(1, at: 0)
        exponent += 1
      }
    }
    let text = "\(value < 0 ? "-" : "")0.\(kept.map(String.init).joined())e\(exponent)"
    return Double(text) ?? value
  }

  /// JavaScript's `Math.round`: halves round up.
  static func round(_ value: Double) -> Double {
    (value + 0.5).rounded(.down)
  }

  /// The UTC date and time of `millis` since 1970: `"2026-03-01"` and `"12:00:00"`, with the
  /// milliseconds apart.
  static func civil(_ millis: Int64) -> (date: String, time: TimeOfDay) {
    let days = millis >= 0 ? millis / dayMillis : -((-millis + dayMillis - 1) / dayMillis)
    let rest = millis - days * dayMillis
    let civil = civilDate(days)
    let monthDay = "\(pad(civil.month, 2))-\(pad(civil.day, 2))"
    let date: String
    if (0...9999).contains(civil.year) {
      date = "\(pad(civil.year, 4))-\(monthDay)"
    } else {
      // As `toISOString` writes years outside 0-9999.
      date = "\(civil.year < 0 ? "-" : "+")\(pad(abs(civil.year), 6))-\(monthDay)"
    }
    return (date, TimeOfDay(millis: rest))
  }

  /// A time of day.
  struct TimeOfDay {
    let millis: Int64

    /// `"12:00:00"`.
    var text: String {
      let seconds = millis / 1000
      return "\(pad(seconds / 3600, 2)):\(pad(seconds / 60 % 60, 2)):\(pad(seconds % 60, 2))"
    }

    /// `"12:00:00.250"`.
    var textWithMillis: String { "\(text).\(pad(millis % 1000, 3))" }
  }

  static func pad(_ value: Int64, _ width: Int, hex: Bool = false) -> String {
    let digits = String(value, radix: hex ? 16 : 10)
    return String(repeating: "0", count: max(0, width - digits.count)) + digits
  }

  /// The start of `text` up to `count` UTF-16 units, as JavaScript's `slice` counts, without
  /// splitting a character's surrogate pair.
  static func prefix(_ text: String, utf16Count count: Int) -> String {
    guard text.utf16.count > count else { return text }
    var length = 0
    var result = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      length += scalar.utf16.count
      if length > count { break }
      result.append(scalar)
    }
    return String(result)
  }

  /// A proleptic Gregorian date.
  struct CivilDate {
    let year: Int64
    let month: Int64
    let day: Int64
  }

  /// Days since 1970-01-01 as a proleptic Gregorian date.
  private static func civilDate(_ days: Int64) -> CivilDate {
    let shifted = days + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let monthIndex = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
    let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return CivilDate(year: year, month: month, day: day)
  }

  /// Days since 1970-01-01 of a proleptic Gregorian date.
  static func days(year: Int64, month: Int64, day: Int64) -> Int64 {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }
}
