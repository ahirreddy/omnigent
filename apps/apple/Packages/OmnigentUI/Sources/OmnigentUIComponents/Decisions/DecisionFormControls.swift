import Foundation
import SwiftUI

// The parts of a form field beyond the plain control: placeholders and keyboards for formatted
// text, a date picker for dates, and the range and count hints. The core still checks every rule.

/// Hints a field shows under its control.
enum FormFieldHint {
  /// What a formatted text field shows while empty.
  static func placeholder(_ format: TextFormat) -> String {
    switch format {
    case .email: "name@example.com"
    case .uri: "https://"
    case .date: "YYYY-MM-DD"
    case .dateTime: "YYYY-MM-DDTHH:MM:SS+00:00"
    }
  }

  /// "Between 1 and 10" for a number field with bounds.
  static func range(_ field: FormField) -> String? {
    guard field.kind == .number || field.kind == .integer else { return nil }
    switch (field.minimum, field.maximum) {
    case (let lowest?, let highest?): return "Between \(number(lowest)) and \(number(highest))"
    case (let lowest?, nil): return "At least \(number(lowest))"
    case (nil, let highest?): return "At most \(number(highest))"
    case (nil, nil): return nil
    }
  }

  /// "Choose up to 2" for a multiple choice with item counts.
  static func choices(_ field: FormField) -> String? {
    guard field.kind == .multipleChoice else { return nil }
    switch (field.minItems, field.maxItems) {
    case (let fewest?, let most?) where fewest == most: return "Choose \(fewest)"
    case (let fewest?, let most?) where fewest > 1: return "Choose \(fewest) to \(most)"
    case (_, let most?): return "Choose up to \(most)"
    case (let fewest?, nil) where fewest > 1: return "Choose at least \(fewest)"
    default: return nil
    }
  }

  /// A bound as written in a schema: `10`, not `10.0`.
  static func number(_ value: Double) -> String {
    value.formatted(.number.grouping(.never))
  }

  /// A hint line.
  static func text(_ hint: String) -> some View {
    Text(hint)
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

/// The text of `date` (`2026-11-17`) and `date-time` (`2026-11-17T13:05:00-08:00`) answers, in
/// the user's time zone.
enum FormDateText {
  private static func formatter(_ format: TextFormat) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    formatter.formatOptions = format == .date ? [.withFullDate] : [.withInternetDateTime]
    return formatter
  }

  /// `date` as the field's text.
  static func string(from date: Date, format: TextFormat) -> String {
    formatter(format).string(from: date)
  }

  /// The date the field's text names, if it is in the format.
  static func date(from text: String, format: TextFormat) -> Date? {
    formatter(format).date(from: text.trimmingCharacters(in: .whitespaces))
  }
}

/// A date picker beside a `date` or `date-time` field, kept in step with its text. While the text
/// names no date it offers Today (or Now) instead, so an empty field never looks answered.
struct FormDateEntry: View {
  let format: TextFormat
  let title: String
  @Binding var text: String

  var body: some View {
    if let date = FormDateText.date(from: text, format: format) {
      DatePicker(
        title,
        selection: Binding(
          get: { date }, set: { text = FormDateText.string(from: $0, format: format) }),
        displayedComponents: format == .date ? [.date] : [.date, .hourAndMinute]
      )
      .datePickerStyle(.compact)
      .labelsHidden()
      .accessibilityLabel(title)
    } else {
      Button(format == .date ? "Today" : "Now") {
        text = FormDateText.string(from: Date(), format: format)
      }
      .buttonStyle(.bordered)
      .accessibilityLabel(format == .date ? "Use today for \(title)" : "Use now for \(title)")
    }
  }
}

extension View {
  /// The keyboard and input behavior for formatted text: no autocorrection or capitals, and the
  /// email or URL keyboard on iPhone and iPad.
  @ViewBuilder
  func textEntry(for format: TextFormat) -> some View {
    #if os(iOS)
      switch format {
      case .email:
        keyboardType(.emailAddress).textContentType(.emailAddress)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      case .uri:
        keyboardType(.URL).textContentType(.URL)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      case .date, .dateTime:
        keyboardType(.numbersAndPunctuation)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      }
    #else
      autocorrectionDisabled()
    #endif
  }
}
