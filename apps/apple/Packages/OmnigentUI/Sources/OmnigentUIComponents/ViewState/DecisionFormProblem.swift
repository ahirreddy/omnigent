/// A problem the core's form validator found, and the field it is about.
nonisolated public struct DecisionFormProblem: Hashable, Sendable {
  /// What is wrong, for display.
  public var message: String
  /// The key of the field it is about; `nil` when it names no field or the validator did not say.
  public var fieldKey: String?

  /// Creates a problem.
  /// - Parameters:
  ///   - message: What is wrong.
  ///   - fieldKey: The field's key, when the problem is about one.
  public init(message: String, fieldKey: String? = nil) {
    self.message = message
    self.fieldKey = fieldKey
  }

  /// The field to show the problem under: the one with ``fieldKey``. Without a key (an older
  /// validator), the field whose title the message names.
  func field(in fields: [FormField]) -> FormField? {
    guard let fieldKey else { return FormDraft.field(for: message, in: fields) }
    return fields.first { $0.key == fieldKey }
  }
}
