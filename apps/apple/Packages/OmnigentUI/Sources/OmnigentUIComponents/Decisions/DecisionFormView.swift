import SwiftUI

/// What the user has entered into a decision card so far: form answers and the "Tell the agent
/// instead" reply. Kept per card id and shared by the inline card, the dock and the iPhone sheet,
/// so a half-written answer survives scrolling, paging and size-class changes. A field the user
/// has not touched reads its default.
struct FormDraft: Hashable {
  var text: [String: String] = [:]
  var selected: [String: [String]] = [:]
  var custom: [String: String] = [:]
  var booleans: [String: Bool] = [:]
  /// Notes on answers, for fields that take one.
  var notes: [String: String] = [:]
  /// The reply for "Tell the agent instead".
  var feedback = ""
  /// The reply field is open.
  var isComposingFeedback = false

  /// The text a text or number field shows: what was typed, else its default.
  func text(for field: FormField) -> String {
    if let typed = text[field.key] { return typed }
    switch field.defaultValue {
    case .text(let value): return value
    case .integer(let value): return String(value)
    case .number(let value): return String(value)
    case .bool, .textList, .null, nil: return ""
    }
  }

  /// The options a choice field has selected: what was chosen, else its default.
  func selection(for field: FormField) -> [String] {
    if let chosen = selected[field.key] { return chosen }
    switch field.defaultValue {
    case .text(let value): return [value]
    case .textList(let values): return values
    case .bool, .integer, .number, .null, nil: return []
    }
  }

  /// A yes-or-no field's answer: what was chosen, else its default; `nil` while unanswered.
  func booleanAnswer(for field: FormField) -> ElicitationValue? {
    if let chosen = booleans[field.key] { return .bool(value: chosen) }
    if case .bool = field.defaultValue { return field.defaultValue }
    return nil
  }

  /// A problem the UI itself can see: unparseable numbers and missing required answers.
  /// Constraint checks (lengths, ranges, item counts, formats) are the core's validator.
  func localProblem(for fields: [FormField]) -> String? {
    fields.lazy.compactMap { problem(for: $0)?.message }.first
  }

  /// The local problem with one field, shown under that field.
  func problem(for field: FormField) -> FieldProblem? {
    switch field.kind {
    case .number, .integer:
      return numberProblem(for: field)
    case .text:
      return field.required && !field.exactText && text(for: field).isEmpty
        ? .missing(Self.sentence("Enter \(field.title)")) : nil
    case .boolean:
      return field.required && booleanAnswer(for: field) == nil
        ? .missing(Self.sentence("Choose Yes or No for \(field.title)")) : nil
    case .singleChoice, .multipleChoice:
      return field.required && value(for: field) == nil
        ? .missing(Self.sentence("Choose an answer for \(field.title)")) : nil
    }
  }

  /// Why Submit is off, or `nil` when it can be sent. A harness question names the first one
  /// still unanswered as the web does ("Answer question 2 (Platforms) to submit"); another form
  /// gives its first field's problem. A validator problem no field shows stands as it is.
  func submitBlockedReason(
    for fields: [FormField], asQuestions: Bool, validatorProblem: String?
  ) -> String? {
    for (index, field) in fields.enumerated() {
      guard let problem = problem(for: field) else { continue }
      guard asQuestions, !problem.isInvalid else { return problem.message }
      let header = field.detail.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Answer question \(index + 1)\(header.isEmpty ? "" : " (\(header))") to submit"
    }
    return validatorProblem
  }

  /// `text` ending as a sentence: a full stop unless a question's own mark already ends it.
  static func sentence(_ text: String) -> String {
    text.last.map { ".?!".contains($0) } == true ? text : text + "."
  }

  private func numberProblem(for field: FormField) -> FieldProblem? {
    let raw = text(for: field).trimmingCharacters(in: .whitespaces)
    if raw.isEmpty { return field.required ? .missing(Self.sentence("Enter \(field.title)")) : nil }
    if field.kind == .integer, Int64(raw) == nil {
      return .invalid("\(field.title) must be a whole number.")
    }
    if field.kind == .number, Double(raw).map(\.isFinite) != true {
      return .invalid("\(field.title) must be a number.")
    }
    return nil
  }

  /// The field a keyless validator message is about (older validators), so it shows next to
  /// that field: the field whose title the message names (the longest, when titles overlap).
  /// `nil` keeps it with Submit.
  nonisolated static func field(for message: String, in fields: [FormField]) -> FormField? {
    fields.filter { !$0.title.isEmpty && message.localizedCaseInsensitiveContains($0.title) }
      .max { $0.title.count < $1.title.count }
  }

  /// The typed answers. Fields left empty are omitted.
  func values(for fields: [FormField]) -> [String: ElicitationValue] {
    var values: [String: ElicitationValue] = [:]
    for field in fields {
      if let value = value(for: field) { values[field.key] = value }
    }
    return values
  }

  private func value(for field: FormField) -> ElicitationValue? {
    let other = custom[field.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
    switch field.kind {
    case .text:
      // An editor's text is the answer even when empty.
      let raw = text(for: field)
      return raw.isEmpty && !field.exactText ? nil : .text(value: raw)
    case .integer:
      return Int64(text(for: field).trimmingCharacters(in: .whitespaces))
        .map { .integer(value: $0) }
    case .number:
      guard let number = Double(text(for: field).trimmingCharacters(in: .whitespaces)),
        number.isFinite
      else { return nil }
      return .number(value: number)
    case .boolean:
      return booleanAnswer(for: field)
    case .singleChoice:
      if field.allowsCustom, !other.isEmpty { return .text(value: other) }
      return selection(for: field).first.map { .text(value: $0) }
    case .multipleChoice:
      let chosen = selection(for: field)
      var choices = field.options.map(\.value).filter { chosen.contains($0) }
      if field.allowsCustom, !other.isEmpty, !choices.contains(other) { choices.append(other) }
      return choices.isEmpty ? nil : .textList(values: choices)
    }
  }
}

/// Why one field's answer can't be sent yet.
struct FieldProblem: Hashable {
  let message: String
  /// The answer is there but wrong (an error), rather than still missing (a hint).
  let isInvalid: Bool

  static func missing(_ message: String) -> Self { Self(message: message, isInvalid: false) }
  static func invalid(_ message: String) -> Self { Self(message: message, isInvalid: true) }
}

extension View {
  /// Says why a disabled Submit is off while the pointer rests on it. A disabled control shows
  /// no tooltip of its own, so the reason sits on a wrapper around it.
  func submitBlockedHelp(_ reason: String?) -> some View {
    ZStack { self }
      .contentShape(Rectangle())
      .help(reason ?? "")
  }
}

/// The fields of a form decision, laid out as native controls. Each field's problem shows right
/// under it: the local one first, else the validator's when it names that field.
struct DecisionFormFields: View {
  let fields: [FormField]
  @Binding var draft: FormDraft
  let cardID: String
  /// The core validator's problem, attributed to a field by ``DecisionFormProblem/field(in:)``.
  var validatorProblem: (key: String, message: String)?
  @Environment(\.decisionIDPrefix) private var idPrefix

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      ForEach(fields) { field in
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
          HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
            Text(field.title).font(.callout.weight(.semibold))
            Text(field.required ? "Required" : "Optional")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if !field.detail.isEmpty {
            Text(field.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          control(for: field)
          if let problem = problem(for: field) {
            Label(problem.message, systemImage: "exclamationmark.circle")
              .font(.caption)
              .foregroundStyle(problem.isInvalid ? Theme.failure : Theme.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("\(idPrefix)request-field-problem-\(cardID)-\(field.key)")
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("\(idPrefix)request-field-\(cardID)-\(field.key)")
      }
    }
  }

  private func problem(for field: FormField) -> FieldProblem? {
    if let local = draft.problem(for: field) { return local }
    guard let validatorProblem, validatorProblem.key == field.key else { return nil }
    return .invalid(validatorProblem.message)
  }

  @ViewBuilder
  private func control(for field: FormField) -> some View {
    switch field.kind {
    case .text, .number, .integer:
      textControl(field)
    case .boolean:
      Picker(field.title, selection: booleanBinding(field)) {
        Text("Yes").tag(YesNo.answeredYes)
        Text("No").tag(YesNo.answeredNo)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    case .singleChoice, .multipleChoice:
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        optionControls(field)
        if field.allowsCustom {
          Group {
            if field.isSecret {
              SecureField("Other answer", text: customBinding(field))
            } else {
              TextField("Other answer", text: customBinding(field), axis: .vertical)
            }
          }
          .textFieldStyle(.roundedBorder)
          .padding(.top, Theme.Spacing.extraSmall)
          .accessibilityLabel("Other answer for \(field.title)")
        }
        if let hint = FormFieldHint.choices(field) { FormFieldHint.text(hint) }
        if let option = draft.previewedOption(for: field) {
          OptionPreview(option: option)
            .padding(.top, Theme.Spacing.extraSmall)
            .accessibilityIdentifier("\(idPrefix)request-field-preview-\(cardID)-\(field.key)")
        }
        if field.acceptsNotes { notesControl(field) }
      }
    }
  }

  private func notesControl(_ field: FormField) -> some View {
    TextField(
      "Notes (optional)",
      text: Binding(
        get: { draft.notes[field.key, default: ""] }, set: { draft.notes[field.key] = $0 }),
      axis: .vertical
    )
    .lineLimit(1...4)
    .textFieldStyle(.roundedBorder)
    .padding(.top, Theme.Spacing.extraSmall)
    .accessibilityLabel("Notes for \(field.title)")
    .accessibilityIdentifier("\(idPrefix)request-field-notes-\(cardID)-\(field.key)")
  }

  @ViewBuilder
  private func textControl(_ field: FormField) -> some View {
    let binding = textBinding(field)
    HStack(spacing: Theme.Spacing.small) {
      Group {
        if field.isSecret {
          SecureField(field.title, text: binding)
        } else if let format = field.format {
          TextField(FormFieldHint.placeholder(format), text: binding)
            .textEntry(for: format)
        } else if field.kind == .text {
          TextField(field.title, text: binding, axis: .vertical)
            .lineLimit(field.exactText ? 4...12 : 1...6)
        } else {
          TextField(field.kind == .integer ? "Whole number" : "Number", text: binding)
            #if os(iOS)
              .keyboardType(field.kind == .integer ? .numberPad : .decimalPad)
            #endif
        }
      }
      .textFieldStyle(.roundedBorder)
      .labelsHidden()
      .accessibilityLabel(field.title)
      if let format = field.format, format == .date || format == .dateTime {
        FormDateEntry(format: format, title: field.title, text: binding)
      }
    }
    if let maxLength = field.maxLength, field.kind == .text {
      let count = binding.wrappedValue.unicodeScalars.count
      Text("\(count) of \(maxLength) characters")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(UInt64(count) > maxLength ? Theme.failure : .secondary)
    }
    if let hint = FormFieldHint.range(field) { FormFieldHint.text(hint) }
  }

  private func toggle(_ value: String, in field: FormField) {
    var current = draft.selection(for: field)
    if field.kind == .singleChoice {
      current = [value]
      draft.custom[field.key] = nil
    } else if let index = current.firstIndex(of: value) {
      current.remove(at: index)
    } else {
      current.append(value)
    }
    draft.selected[field.key] = current
  }

  /// A choice's options: radio rows or checkboxes, or a pop-up menu for a long plain list.
  @ViewBuilder
  private func optionControls(_ field: FormField) -> some View {
    if Self.choosesFromMenu(field) {
      Picker(field.title, selection: menuBinding(field)) {
        Text("Choose\u{2026}").tag(String?.none)
        ForEach(field.options) { option in
          Text(option.label).tag(String?.some(option.value))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .fixedSize()
      .accessibilityLabel(field.title)
    } else {
      ForEach(field.options) { option in
        OptionRow(
          option: option, isMultiple: field.kind == .multipleChoice,
          isSelected: draft.selection(for: field).contains(option.value)
        ) {
          toggle(option.value, in: field)
        }
      }
    }
  }

  /// Most options a single choice lists as radio rows; a longer plain list is a pop-up menu.
  static let menuThreshold = 10

  /// A long single choice whose options are bare labels (a Pi select, a model list) picks from a
  /// menu, as a Mac or iOS settings list would.
  static func choosesFromMenu(_ field: FormField) -> Bool {
    field.kind == .singleChoice && field.options.count > menuThreshold
      && field.options.allSatisfy { $0.detail.isEmpty && $0.preview.isEmpty }
  }

  private func menuBinding(_ field: FormField) -> Binding<String?> {
    Binding(
      get: { draft.selection(for: field).first },
      set: { value in
        if let value { toggle(value, in: field) } else { draft.selected[field.key] = [] }
      })
  }

  private func textBinding(_ field: FormField) -> Binding<String> {
    Binding(get: { draft.text(for: field) }, set: { draft.text[field.key] = $0 })
  }

  /// A yes/no answer; `unanswered` is distinct from No.
  private enum YesNo: Hashable {
    case unanswered
    case answeredYes
    case answeredNo
  }

  private func booleanBinding(_ field: FormField) -> Binding<YesNo> {
    Binding(
      get: {
        switch draft.booleanAnswer(for: field) {
        case .bool(value: true): .answeredYes
        case .bool(value: false): .answeredNo
        default: .unanswered
        }
      },
      set: { answer in
        switch answer {
        case .answeredYes: draft.booleans[field.key] = true
        case .answeredNo: draft.booleans[field.key] = false
        case .unanswered: draft.booleans[field.key] = nil
        }
      })
  }

  private func customBinding(_ field: FormField) -> Binding<String> {
    Binding(
      get: { draft.custom[field.key, default: ""] },
      set: { newValue in
        draft.custom[field.key] = newValue
        if field.kind == .singleChoice, !newValue.isEmpty { draft.selected[field.key] = [] }
      })
  }
}
