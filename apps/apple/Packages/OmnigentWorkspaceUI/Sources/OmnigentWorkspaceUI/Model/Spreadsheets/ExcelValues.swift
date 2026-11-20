import Foundation

/// How a cell style shows a date serial (web `DateStyle`).
nonisolated enum ExcelDateStyle: Hashable {
  /// A date, with the time when the serial has one.
  case date
  /// Only the time of day.
  case time
  /// Elapsed time counted in its largest unit past a day, for example `[h]:mm:ss`.
  case elapsed(ExcelElapsedFormat)
}

/// How an elapsed format counts: its largest unit, and whether it shows seconds.
nonisolated struct ExcelElapsedFormat: Hashable {
  enum Unit: Hashable {
    case hours
    case minutes
    case seconds
  }

  let unit: Unit
  let showsSeconds: Bool
}

/// Excel's number formats and date serials, as the web's `xlsx.ts` reads them.
nonisolated enum ExcelValues {
  /// Built-in formats that show only a time of day, for example 21 is `h:mm:ss`.
  static let builtInTimeFormats: Set<Int> = [18, 19, 20, 21, 45, 47]
  /// The built-in elapsed format, `[h]:mm:ss`.
  static let builtInElapsedFormat = 46
  /// Built-in formats that show a date or time.
  static let builtInDateFormats = Set([14, 15, 16, 17, 18, 19, 20, 21, 22, 45, 46, 47])
    .union(27...36).union(50...58)

  // Day zero of each date system, in milliseconds since 1970. Excel's 1900 system counts a
  // 29 February 1900 that never was (serial 60): this epoch is right from March 1900 on.
  private static let epoch1900 = SpreadsheetText.days(year: 1899, month: 12, day: 30) * dayMillis
  private static let epoch1904 = SpreadsheetText.days(year: 1904, month: 1, day: 1) * dayMillis
  private static let phantomLeapDay = 60.0
  /// The end of 9999-12-31, the last moment Excel shows as a date.
  private static let lastDateMillis =
    SpreadsheetText.days(year: 10_000, month: 1, day: 1) * dayMillis
  private static let dayMillis = SpreadsheetText.dayMillis

  /// A format code without its quoted text, escapes and brackets other than elapsed units.
  static func bareFormat(_ code: String) -> String {
    let characters = Array(code)
    var bare = ""
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if character == "\"", let close = characters[(index + 1)...].firstIndex(of: "\"") {
        index = close + 1
      } else if character == "\\", index + 1 < characters.count {
        index += 2
      } else if character == "[", let close = characters[(index + 1)...].firstIndex(of: "]") {
        let inner = String(characters[(index + 1)..<close])
        if isElapsedUnit(inner) { bare += "[\(inner)]" }
        index = close + 1
      } else {
        bare.append(character)
        index += 1
      }
    }
    return bare
  }

  /// `h`, `mm` or `sss`: one unit letter, repeated.
  private static func isElapsedUnit(_ inner: String) -> Bool {
    let lower = inner.lowercased()
    guard let first = lower.first, "hms".contains(first) else { return false }
    return lower.allSatisfy { $0 == first }
  }

  /// Whether a custom number format shows a date or time, for example `yyyy-mm-dd`.
  static func isDateFormat(_ code: String) -> Bool {
    let bare = bareFormat(code).lowercased()
    return bare.contains(where: { "dmyhs".contains($0) }) && !bare.contains("general")
  }

  /// Whether a date or time format shows only a time of day, for example `hh:mm`.
  static func isTimeFormat(_ code: String) -> Bool {
    let bare = bareFormat(code).lowercased()
    // `m` next to `h` or `s` is minutes; three or more is a month; `e`, `g` and `b` are eras.
    return bare.contains(where: { "hs".contains($0) })
      && !bare.contains(where: { "dyegb".contains($0) }) && !bare.contains("mmm")
      && elapsedFormat(code) == nil
  }

  /// How an elapsed format counts, for example `[mm]:ss` is minutes with seconds; `nil` for a
  /// format that isn't elapsed.
  static func elapsedFormat(_ code: String) -> ExcelElapsedFormat? {
    let bare = bareFormat(code).lowercased()
    // Only elapsed units stay bracketed in the bare format; the rest is outside them.
    var outside = ""
    var letter: Character?
    var rest = Substring(bare)
    while let start = rest.firstIndex(of: "["), let end = rest[start...].firstIndex(of: "]") {
      outside += rest[..<start]
      letter = letter ?? rest[start...].dropFirst().first
      rest = rest[rest.index(after: end)...]
    }
    outside += rest
    guard let letter else { return nil }
    let unit: ExcelElapsedFormat.Unit =
      switch letter {
      case "h": .hours
      case "m": .minutes
      default: .seconds
      }
    // Seconds show when the unit is seconds or an `s` follows outside the brackets.
    return ExcelElapsedFormat(unit: unit, showsSeconds: unit == .seconds || outside.contains("s"))
  }

  /// Each cell format's date style, by its index (web `dateStyles`).
  static func dateStyles(_ styles: StylesXML?) -> [Int: ExcelDateStyle] {
    guard let styles else { return [:] }
    var dated: [Int: ExcelDateStyle] = [:]
    for (index, id) in styles.cellFormats.enumerated() {
      let code = styles.customFormats[id]
      guard code.map(isDateFormat) ?? builtInDateFormats.contains(id) else { continue }
      let elapsed: ExcelElapsedFormat? =
        if let code {
          elapsedFormat(code)
        } else {
          id == builtInElapsedFormat ? ExcelElapsedFormat(unit: .hours, showsSeconds: true) : nil
        }
      let timeOnly = code.map(isTimeFormat) ?? builtInTimeFormats.contains(id)
      dated[index] = elapsed.map(ExcelDateStyle.elapsed) ?? (timeOnly ? .time : .date)
    }
    return dated
  }

  /// An Excel date serial as ISO text: a date, a time, or both (web `excelSerialToText`).
  /// - Parameters:
  ///   - serial: Days since the workbook's epoch, for example `46082.5`.
  ///   - date1904: The workbook uses the 1904 date system.
  ///   - timeOnly: The cell's format shows only a time of day.
  /// - Returns: For example `"2026-03-01"`, `"12:00:00"` or `"2026-03-01 12:00:00"`.
  static func serialText(_ serial: Double, date1904: Bool, timeOnly: Bool = false) -> String {
    // Excel shows times to the nearest second, so the day is the rounded serial's.
    let seconds = SpreadsheetText.round(serial * Double(dayMillis) / 1000)
    let rounded = seconds * 1000 / Double(dayMillis)
    let epoch =
      date1904 ? epoch1904 : (rounded < phantomLeapDay ? epoch1900 + dayMillis : epoch1900)
    let millis = Double(epoch) + seconds * 1000
    // Excel shows no date before its epoch or past 9999; the number stays visible.
    guard serial >= 0, millis < Double(lastDateMillis) else {
      return SpreadsheetText.excelNumber(SpreadsheetText.number(serial))
    }
    let (isoDay, time) = SpreadsheetText.civil(Int64(millis))
    // Excel shows the phantom day as the date it counts.
    let day = !date1904 && rounded.rounded(.down) == phantomLeapDay ? "1900-02-29" : isoDay
    if timeOnly { return time.text }
    if serial == serial.rounded(.down) { return day }
    // The 1900 system's day zero isn't a date Excel names; the 1904 system's is.
    return serial < 1 && !date1904 ? time.text : "\(day) \(time.text)"
  }

  /// Elapsed time counted in `format`'s largest unit, as Excel shows it: 1.5 days is
  /// `"36:00:00"` as `[h]:mm:ss` and `"2160:00"` as `[mm]:ss` (web `elapsedText`).
  static func elapsedText(_ days: Double, format: ExcelElapsedFormat) -> String {
    let step = format.showsSeconds ? 1.0 : 60.0
    let scaled = SpreadsheetText.round(abs(days) * 86_400 / step) * step
    // Past this the count is no longer a whole number of seconds.
    guard scaled < 1e15 else { return SpreadsheetText.excelNumber(SpreadsheetText.number(days)) }
    let total = Int64(scaled)
    let minutes = total / 60
    let seconds = format.showsSeconds ? ":\(SpreadsheetText.pad(total % 60, 2))" : ""
    let text =
      switch format.unit {
      case .hours: "\(minutes / 60):\(SpreadsheetText.pad(minutes % 60, 2))\(seconds)"
      case .minutes: "\(minutes)\(seconds)"
      case .seconds: "\(total)"
      }
    return days < 0 ? "-\(text)" : text
  }

  /// `"BC12"` is 54: the zero-based column of a cell reference's letters; `nil` without letters.
  static func columnIndex(_ reference: String) -> Int? {
    var index = 0
    for scalar in reference.unicodeScalars {
      guard ("A"..."Z").contains(scalar) else { break }
      index = index * 26 + Int(scalar.value) - 64
      // Excel's last column is XFD; anything past it isn't a reference.
      if index > 16_384 { return nil }
    }
    return index > 0 ? index - 1 : nil
  }
}
