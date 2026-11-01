import OmnigentCoreFFI
import Testing

/// The core's form validator, through the bindings: each problem names its field by key.
@Suite("Form validation")
struct FormValidationTests {
  private func field(
    _ key: String, _ title: String, _ kind: FieldKind, maxLength: UInt64? = nil
  ) -> FormField {
    FormField(
      key: key, title: title, detail: "", kind: kind, required: true, options: [],
      allowsCustom: false, isSecret: false, minimum: nil, maximum: nil, minLength: nil,
      maxLength: maxLength, minItems: nil, maxItems: nil)
  }

  @Test("a problem carries the key of the field it is about")
  func keyedProblem() {
    // "PR" is inside "PR title": only the key can tell which field a message is about.
    let fields = [
      field("pr", "PR", .integer), field("title", "PR title", .text, maxLength: 5),
    ]
    let tooLong = validateForm(
      fields: fields, values: ["pr": .integer(value: 7), "title": .text(value: "Too long")])
    #expect(tooLong?.fieldKey == "title")
    #expect(tooLong?.message == "PR title allows at most 5 characters.")
    let missing = validateForm(fields: fields, values: ["title": .text(value: "Fix")])
    #expect(missing?.fieldKey == "pr")
    let unknown = validateForm(
      fields: fields,
      values: ["pr": .integer(value: 7), "title": .text(value: "Fix"), "extra": .null])
    #expect(unknown != nil)
    #expect(unknown?.fieldKey == nil)
    #expect(
      validateForm(
        fields: fields, values: ["pr": .integer(value: 7), "title": .text(value: "Fix")])
        == nil)
  }
}
