import Foundation

// Mirrors of the core's form records (`omnigent-ffi` `decisions.rs`): the fields of a form card.

/// One choice a form field offers.
nonisolated public struct FormOption: Hashable, Sendable, Identifiable {
  /// The value posted when chosen.
  public var value: String
  /// What to show.
  public var label: String
  /// Extra description.
  public var detail: String

  /// The option's identity is its value; values are unique within a field.
  public var id: String { value }

  /// Creates an option.
  /// - Parameters:
  ///   - value: Posted value.
  ///   - label: Display label.
  ///   - detail: Extra description.
  public init(value: String, label: String? = nil, detail: String = "") {
    self.value = value
    self.label = label ?? value
    self.detail = detail
  }
}

/// The native control a field needs.
nonisolated public enum FieldKind: String, Hashable, Sendable, CaseIterable {
  /// Free text.
  case text
  /// A number.
  case number
  /// A whole number.
  case integer
  /// A toggle.
  case boolean
  /// One option.
  case singleChoice
  /// Several options.
  case multipleChoice
}

/// A format a text field's answer must match. The core checks it; the field only offers the
/// right keyboard, a placeholder and, for dates, a picker.
nonisolated public enum TextFormat: String, Hashable, Sendable, CaseIterable {
  /// An email address.
  case email
  /// An absolute URL.
  case uri
  /// `YYYY-MM-DD`.
  case date
  /// `YYYY-MM-DDTHH:MM:SS` with an offset or `Z`.
  case dateTime
}

/// One form field.
nonisolated public struct FormField: Hashable, Sendable, Identifiable {
  /// The `content` key.
  public var key: String
  /// Label.
  public var title: String
  /// Help text.
  public var detail: String
  /// The control.
  public var kind: FieldKind
  /// Must be answered.
  public var required: Bool
  /// Offered choices.
  public var options: [FormOption]
  /// A free-text answer is allowed besides the options.
  public var allowsCustom: Bool
  /// Render as a secure field.
  public var isSecret: Bool
  /// An editor: the text exactly as typed, empty included, is the answer.
  public var exactText: Bool
  /// Lowest number.
  public var minimum: Double?
  /// Highest number.
  public var maximum: Double?
  /// Shortest text.
  public var minLength: UInt64?
  /// Longest text.
  public var maxLength: UInt64?
  /// Fewest choices.
  public var minItems: UInt64?
  /// Most choices.
  public var maxItems: UInt64?
  /// The format a text answer must match.
  public var format: TextFormat?
  /// The answer the field starts with until the user changes it; always a valid answer.
  public var defaultValue: ElicitationValue?

  /// The field's identity is its key.
  public var id: String { key }

  /// Creates a field.
  /// - Parameters:
  ///   - key: Content key.
  ///   - title: Label.
  ///   - detail: Help text.
  ///   - kind: Control.
  ///   - required: Must be answered.
  ///   - options: Choices.
  ///   - allowsCustom: Free text allowed.
  ///   - isSecret: Secure entry.
  ///   - exactText: The exact text, empty included, is the answer.
  ///   - minimum: Lowest number.
  ///   - maximum: Highest number.
  ///   - minLength: Shortest text.
  ///   - maxLength: Longest text.
  ///   - minItems: Fewest choices.
  ///   - maxItems: Most choices.
  ///   - format: Text format.
  ///   - defaultValue: Starting answer.
  public init(
    key: String, title: String, detail: String = "", kind: FieldKind, required: Bool = true,
    options: [FormOption] = [], allowsCustom: Bool = false, isSecret: Bool = false,
    exactText: Bool = false, minimum: Double? = nil, maximum: Double? = nil,
    minLength: UInt64? = nil, maxLength: UInt64? = nil, minItems: UInt64? = nil,
    maxItems: UInt64? = nil, format: TextFormat? = nil, defaultValue: ElicitationValue? = nil
  ) {
    self.key = key
    self.title = title
    self.detail = detail
    self.kind = kind
    self.required = required
    self.options = options
    self.allowsCustom = allowsCustom
    self.isSecret = isSecret
    self.exactText = exactText
    self.minimum = minimum
    self.maximum = maximum
    self.minLength = minLength
    self.maxLength = maxLength
    self.minItems = minItems
    self.maxItems = maxItems
    self.format = format
    self.defaultValue = defaultValue
  }
}
