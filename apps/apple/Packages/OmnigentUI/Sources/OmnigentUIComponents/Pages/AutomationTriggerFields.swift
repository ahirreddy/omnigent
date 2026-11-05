import SwiftUI

/// A trigger template's fields in the automation editor: the event and scope, "and" condition
/// rows, the instructions each started session gets, and the link-back toggle. The prompt they
/// render can be taken over as a plain prompt.
struct AutomationTriggerFields: View {
  @Binding var trigger: AutomationTriggerDraft
  let template: AutomationTriggerTemplate
  let renderedPrompt: String
  let editAsPrompt: () -> Void

  var body: some View {
    Section("When") {
      Picker("Event", selection: $trigger.event) {
        ForEach(template.events) { Text($0.name).tag($0.id) }
      }
      .accessibilityIdentifier("automation-trigger-event")
      TextField(
        template.scopeLabel.capitalizedFirst, text: $trigger.scope,
        prompt: Text(template.scopePlaceholder)
      )
      .accessibilityIdentifier("automation-trigger-scope")
      ForEach($trigger.conditions) { $condition in
        conditionRow($condition)
      }
      if let first = template.fields.first, let operation = first.operations.first {
        Button("Add condition", systemImage: "plus") {
          trigger.conditions.append(
            AutomationTriggerCondition(field: first.id, operation: operation.id))
        }
        .accessibilityIdentifier("automation-trigger-add-condition")
      }
    }
    Section("Then") {
      TextField(
        "Instructions for each session", text: $trigger.instructions,
        prompt: Text(template.instructionsPlaceholder), axis: .vertical
      )
      .lineLimit(3...8)
      .accessibilityIdentifier("automation-trigger-instructions")
      if trigger.instructions.count > template.maxInstructions {
        Text("Keep the instructions under \(template.maxInstructions) characters.")
          .font(.callout).foregroundStyle(.red)
      }
      Toggle(template.linkBackLabel, isOn: $trigger.linkBack)
        .accessibilityIdentifier("automation-trigger-link-back")
      if !renderedPrompt.isEmpty {
        DisclosureGroup("Prompt each run sends") {
          Text(renderedPrompt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Button("Edit as a prompt", action: editAsPrompt)
          .accessibilityIdentifier("automation-trigger-edit-prompt")
      }
    }
  }

  private func conditionRow(_ condition: Binding<AutomationTriggerCondition>) -> some View {
    let field = template.fields.first { $0.id == condition.wrappedValue.field }
    let operation = field?.operations.first { $0.id == condition.wrappedValue.operation }
    return HStack {
      Picker("And", selection: fieldSelection(condition)) {
        ForEach(template.fields) { Text($0.title).tag($0.id) }
      }
      .fixedSize()
      Picker("Comparison", selection: condition.operation) {
        ForEach(field?.operations ?? []) { Text($0.title).tag($0.id) }
      }
      .labelsHidden()
      .fixedSize()
      if operation?.isValueless != true {
        TextField(
          "Value", text: condition.value, prompt: Text(field?.placeholder ?? "")
        )
        .labelsHidden()
      } else {
        Spacer()
      }
      Button("Remove condition", systemImage: "minus.circle") {
        trigger.conditions.removeAll { $0.id == condition.wrappedValue.id }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
    }
  }

  /// Switching the field resets the comparison to that field's default.
  private func fieldSelection(_ condition: Binding<AutomationTriggerCondition>) -> Binding<String> {
    Binding(
      get: { condition.wrappedValue.field },
      set: { id in
        guard id != condition.wrappedValue.field else { return }
        condition.wrappedValue.field = id
        let operations = template.fields.first { $0.id == id }?.operations ?? []
        condition.wrappedValue.operation = operations.first?.id ?? ""
      })
  }
}

extension String {
  /// The string with its first letter uppercased: "in project" → "In project".
  fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
