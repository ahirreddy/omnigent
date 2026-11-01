import SwiftUI

/// What the user has entered into a decision card so far: form answers and the "Tell the agent
/// instead" reply. Kept per card id and shared by the inline card, the dock and the iPhone sheet,
/// so a half-written answer survives scrolling, paging and size-class changes.
struct FormDraft: Hashable {
  var text: [String: String] = [:]
  var selected: [String: [String]] = [:]
  var custom: [String: String] = [:]
  var booleans: [String: Bool] = [:]
  /// The reply for "Tell the agent instead".
  var feedback = ""
  /// The reply field is open.
  var isComposingFeedback = false

  /// A problem the UI itself can see: unparseable numbers and missing required answers.
  /// Constraint checks (lengths, ranges, item counts) are the core's validator.
  func localProblem(for fields: [FormField]) -> String? {
    fields.lazy.compactMap { problem(for: $0)?.message }.first
  }

  /// The local problem with one field, shown under that field.
  func problem(for field: FormField) -> FieldProblem? {
    switch field.kind {
    case .number, .integer:
      return numberProblem(for: field)
    case .text:
      return field.required && text[field.key, default: ""].isEmpty
        ? .missing("Enter \(field.title).") : nil
    case .boolean:
      return field.required && booleans[field.key] == nil
        ? .missing("Choose Yes or No for \(field.title).") : nil
    case .singleChoice, .multipleChoice:
      return field.required && value(for: field) == nil
        ? .missing("Choose an answer for \(field.title).") : nil
    }
  }

  private func numberProblem(for field: FormField) -> FieldProblem? {
    let raw = text[field.key, default: ""].trimmingCharacters(in: .whitespaces)
    if raw.isEmpty { return field.required ? .missing("Enter \(field.title).") : nil }
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
      let raw = text[field.key, default: ""]
      return raw.isEmpty ? nil : .text(value: raw)
    case .integer:
      return Int64(text[field.key, default: ""].trimmingCharacters(in: .whitespaces))
        .map { .integer(value: $0) }
    case .number:
      guard let number = Double(text[field.key, default: ""].trimmingCharacters(in: .whitespaces)),
        number.isFinite
      else { return nil }
      return .number(value: number)
    case .boolean:
      return booleans[field.key].map { .bool(value: $0) }
    case .singleChoice:
      if field.allowsCustom, !other.isEmpty { return .text(value: other) }
      return selected[field.key]?.first.map { .text(value: $0) }
    case .multipleChoice:
      var choices = field.options.map(\.value).filter {
        selected[field.key, default: []].contains($0)
      }
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
      Picker(field.title, selection: booleanBinding(field.key)) {
        Text("Yes").tag(YesNo.answeredYes)
        Text("No").tag(YesNo.answeredNo)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .fixedSize()
    case .singleChoice, .multipleChoice:
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        ForEach(field.options) { option in
          OptionRow(
            option: option, isMultiple: field.kind == .multipleChoice,
            isSelected: draft.selected[field.key, default: []].contains(option.value)
          ) {
            toggle(option.value, in: field)
          }
        }
        if field.allowsCustom {
          TextField("Other answer", text: customBinding(field), axis: .vertical)
            .textFieldStyle(.roundedBorder)
            .padding(.top, Theme.Spacing.extraSmall)
            .accessibilityLabel("Other answer for \(field.title)")
        }
      }
    }
  }

  @ViewBuilder
  private func textControl(_ field: FormField) -> some View {
    let binding = textBinding(field.key)
    Group {
      if field.isSecret {
        SecureField(field.title, text: binding)
      } else if field.kind == .text {
        TextField(field.title, text: binding, axis: .vertical)
          .lineLimit(1...6)
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
    if let maxLength = field.maxLength, field.kind == .text {
      let count = binding.wrappedValue.unicodeScalars.count
      Text("\(count) of \(maxLength) characters")
        .font(.caption2.monospacedDigit())
        .foregroundStyle(UInt64(count) > maxLength ? Theme.failure : .secondary)
    }
  }

  private func toggle(_ value: String, in field: FormField) {
    var current = draft.selected[field.key, default: []]
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

  private func textBinding(_ key: String) -> Binding<String> {
    Binding(get: { draft.text[key, default: ""] }, set: { draft.text[key] = $0 })
  }

  /// A yes/no answer; `unanswered` is distinct from No.
  private enum YesNo: Hashable {
    case unanswered
    case answeredYes
    case answeredNo
  }

  private func booleanBinding(_ key: String) -> Binding<YesNo> {
    Binding(
      get: {
        switch draft.booleans[key] {
        case true?: .answeredYes
        case false?: .answeredNo
        case nil: .unanswered
        }
      },
      set: { answer in
        switch answer {
        case .answeredYes: draft.booleans[key] = true
        case .answeredNo: draft.booleans[key] = false
        case .unanswered: draft.booleans[key] = nil
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

/// A radio or checkbox row with an optional description.
struct OptionRow: View {
  let option: FormOption
  let isMultiple: Bool
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
        Image(systemName: symbol)
          .foregroundStyle(isSelected ? ThemeColor.primary : ThemeColor.secondary)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text(option.label)
            .fixedSize(horizontal: false, vertical: true)
          if !option.detail.isEmpty {
            Text(option.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.vertical, Theme.Spacing.extraSmall)
      .padding(.horizontal, Theme.Spacing.small)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverHighlight()
    .accessibilityLabel(option.label)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private var symbol: String {
    if isMultiple { return isSelected ? "checkmark.square.fill" : "square" }
    return isSelected ? "largecircle.fill.circle" : "circle"
  }
}
