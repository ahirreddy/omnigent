import NativeLabCore
import SwiftUI

struct RequestFormDraft {
  var text: [String: String] = [:]
  var selected: [String: Set<String>] = [:]
  var custom: [String: String] = [:]
  var booleans: [String: Bool] = [:]

  func values(for form: DecisionForm) -> [String: DecisionValue] {
    var values: [String: DecisionValue] = [:]
    for field in form.fields {
      switch field.kind {
      case .text:
        if let value = text[field.key], !value.isEmpty { values[field.key] = .string(value) }
      case .number, .integer:
        if let raw = text[field.key], let value = Double(raw), value.isFinite {
          values[field.key] = .number(value)
        }
      case .boolean:
        if let value = booleans[field.key] { values[field.key] = .boolean(value) }
      case .singleChoice:
        let other = custom[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if field.allowsCustom && !other.isEmpty {
          values[field.key] = .string(other)
        } else if let first = selected[field.key]?.first {
          values[field.key] = .string(first)
        }
      case .multipleChoice:
        var choices = field.options.map(\.value).filter {
          selected[field.key, default: []].contains($0)
        }
        let other = custom[field.key]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if field.allowsCustom && !other.isEmpty && !choices.contains(other) {
          choices.append(other)
        }
        if !choices.isEmpty { values[field.key] = .strings(choices) }
      }
    }
    return values
  }

  func validationError(for form: DecisionForm) -> String? {
    for field in form.fields where field.kind == .number || field.kind == .integer {
      if let raw = text[field.key], !raw.isEmpty,
        Double(raw).map({ $0.isFinite }) != true
      {
        return "Enter a valid number for \(field.title)."
      }
    }
    return form.validationError(values: values(for: form))
  }
}

struct RequestFormView: View {
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focusedField: String?
  let form: DecisionForm
  let title: String
  let requestID: String
  @Binding var draft: RequestFormDraft
  let isSubmitting: Bool
  let errorMessage: String?
  let submit: ([String: DecisionValue]) -> Void

  var body: some View {
    NavigationStack {
      Form {
        ForEach(form.fields) { field in
          Section {
            fieldControl(field)
          } header: {
            Text(field.title + (field.required ? " · Required" : " · Optional"))
              .textCase(nil)
          } footer: {
            if !field.detail.isEmpty { Text(String(field.detail.prefix(8_000))) }
          }
        }
      }
      .scrollDismissesKeyboard(.interactively)
      .safeAreaInset(edge: .bottom) {
        VStack(alignment: .leading, spacing: 8) {
          if let errorMessage {
            Text(errorMessage).font(.callout).foregroundStyle(.red)
              .accessibilityIdentifier("request-form-error")
          }
          if let error = draft.validationError(for: form) {
            Text(error).font(.caption).foregroundStyle(.secondary)
              .accessibilityIdentifier("request-form-validation")
          }
          Button {
            guard draft.validationError(for: form) == nil else { return }
            submit(draft.values(for: form))
          } label: {
            if isSubmitting {
              ProgressView("Submitting…")
            } else {
              Text("Submit answers").frame(maxWidth: .infinity, minHeight: 44)
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled(isSubmitting || draft.validationError(for: form) != nil)
          .accessibilityIdentifier("request-form-submit")
        }
        .padding().background(.regularMaterial)
      }
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
            .accessibilityIdentifier("request-form-done")
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Hide keyboard") { focusedField = nil }
            .accessibilityIdentifier("request-hide-keyboard")
        }
      }
      .disabled(isSubmitting)
    }
  }

  @ViewBuilder
  private func fieldControl(_ field: DecisionFormField) -> some View {
    switch field.kind {
    case .text, .number, .integer:
      if field.isSecret {
        SecureField(field.title, text: textBinding(field.key))
          .focused($focusedField, equals: field.key)
          .accessibilityIdentifier("request-field-\(field.key)")
      } else {
        TextField(field.title, text: textBinding(field.key), axis: .vertical)
          .focused($focusedField, equals: field.key)
          .keyboardType(field.kind == .text ? .default : .numbersAndPunctuation)
          .textInputAutocapitalization(field.kind == .text ? .sentences : .never)
          .accessibilityIdentifier("request-field-\(field.key)")
      }
    case .boolean:
      ForEach([true, false], id: \.self) { value in
        Button {
          focusedField = nil
          draft.booleans[field.key] = value
        } label: {
          Label(
            value ? "Yes" : "No",
            systemImage: draft.booleans[field.key] == value ? "largecircle.fill.circle" : "circle"
          )
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(draft.booleans[field.key] == value ? "Selected" : "Not selected")
        .accessibilityIdentifier("request-boolean-\(field.key)-\(value ? "yes" : "no")")
      }
    case .singleChoice, .multipleChoice:
      ForEach(Array(field.options.enumerated()), id: \.element.id) { index, option in
        Button {
          focusedField = nil
          if field.kind == .singleChoice {
            draft.selected[field.key] = [option.value]
            draft.custom[field.key] = nil
          } else if draft.selected[field.key, default: []].contains(option.value) {
            draft.selected[field.key, default: []].remove(option.value)
          } else {
            draft.selected[field.key, default: []].insert(option.value)
          }
        } label: {
          HStack(alignment: .top) {
            Image(systemName: selectionSymbol(field, option: option))
            VStack(alignment: .leading, spacing: 6) {
              Text(option.label).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
              if !option.detail.isEmpty {
                Text(String(option.detail.prefix(8_000)))
                  .font(.footnote).foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
        .accessibilityValue(
          draft.selected[field.key, default: []].contains(option.value)
            ? "Selected" : "Not selected"
        )
        .accessibilityIdentifier("request-option-\(field.key)-\(index)")
      }
      if field.allowsCustom {
        if field.isSecret {
          SecureField("Custom answer", text: customBinding(field))
            .focused($focusedField, equals: field.key)
            .accessibilityIdentifier("request-custom-\(field.key)")
        } else {
          TextField("Custom answer", text: customBinding(field), axis: .vertical)
            .focused($focusedField, equals: field.key)
            .accessibilityIdentifier("request-custom-\(field.key)")
        }
      }
    }
  }

  private func textBinding(_ key: String) -> Binding<String> {
    Binding(get: { draft.text[key, default: ""] }, set: { draft.text[key] = $0 })
  }

  private func customBinding(_ field: DecisionFormField) -> Binding<String> {
    Binding(
      get: { draft.custom[field.key, default: ""] },
      set: {
        draft.custom[field.key] = $0
        if field.kind == .singleChoice && !$0.isEmpty { draft.selected[field.key] = [] }
      })
  }

  private func selectionSymbol(_ field: DecisionFormField, option: DecisionFormOption) -> String {
    let selected = draft.selected[field.key, default: []].contains(option.value)
    if field.kind == .multipleChoice { return selected ? "checkmark.square.fill" : "square" }
    return selected ? "largecircle.fill.circle" : "circle"
  }
}
