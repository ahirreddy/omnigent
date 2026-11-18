import SwiftUI

/// A trigger template's fields in the automation editor: the event, its help, the scope and
/// how it matches, the event's inline value, "and" condition rows, the instructions each
/// started session gets, and link-back. The prompt they render can be taken over as a plain
/// prompt.
struct AutomationTriggerFields: View {
  @Binding var trigger: AutomationTriggerDraft
  let template: AutomationTriggerTemplate
  let renderedPrompt: String
  /// The source's own MCP service, when the catalog has one.
  var mcp: AutomationMcpOption?
  @Binding var usesMcp: Bool
  /// Switches the event, as the core's `trigger_fields_for_event`.
  var switchEvent: (@MainActor (String) -> Void)?
  let editAsPrompt: () -> Void

  private var event: AutomationTriggerTemplate.Event? { template.eventDetails[trigger.event] }

  private var fields: [AutomationTriggerTemplate.Field] {
    let hidden = event?.hiddenFields ?? []
    return template.fields.filter { !hidden.contains($0.id) }
  }

  var body: some View {
    Section("When") {
      Picker("Event", selection: eventSelection) {
        ForEach(template.events) { Text($0.name).tag($0.id) }
      }
      .accessibilityIdentifier("automation-trigger-event")
      if let description = event?.description {
        Text(description).font(.callout).foregroundStyle(.secondary)
          .accessibilityIdentifier("automation-trigger-description")
      }
      if template.scopeOperators.count > 1, event?.isGroup != true {
        Picker(
          (event?.scopeLabel ?? template.scopeLabel).capitalizedFirst,
          selection: Binding(
            get: { trigger.scopeOperator ?? "is" }, set: { trigger.scopeOperator = $0 })
        ) {
          ForEach(template.scopeOperators) { Text($0.name).tag($0.id) }
        }
        .accessibilityIdentifier("automation-trigger-scope-operator")
      }
      HStack(spacing: Theme.Spacing.extraSmall) {
        if let prefix = event?.scopePrefix, !prefix.isEmpty {
          Text(prefix).foregroundStyle(.secondary)
        }
        TextField(
          (event?.scopeLabel ?? template.scopeLabel).capitalizedFirst, text: $trigger.scope,
          prompt: Text(event?.scopePlaceholder ?? template.scopePlaceholder)
        )
        .accessibilityIdentifier("automation-trigger-scope")
      }
      if let target = event?.target {
        TextField(
          "\(target.word.capitalizedFirst) (\(target.label.lowercased()))",
          text: Binding(get: { trigger.target ?? "" }, set: { trigger.target = $0 }),
          prompt: Text(target.placeholder)
        )
        .accessibilityIdentifier("automation-trigger-target")
        if target.isRequired, (trigger.target ?? "").trimmingCharacters(in: .whitespaces).isEmpty,
          let hint = target.hint
        {
          Text(hint).font(.callout).foregroundStyle(.secondary)
        }
      }
      ForEach($trigger.conditions) { $condition in
        conditionRow($condition)
      }
      if let first = fields.first, let operation = first.operations.first {
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
      if trigger.instructions.utf16.count > template.maxInstructions {
        Text("Keep the instructions under \(template.maxInstructions.formatted()) characters.")
          .font(.callout).foregroundStyle(.red)
          .accessibilityIdentifier("automation-trigger-instructions-limit")
      }
      if let hint = template.budgetHint {
        Text(hint).font(.callout).foregroundStyle(.secondary)
      }
      Toggle(
        template.linkBackLabel,
        isOn: Binding(
          get: { trigger.linkBack },
          set: {
            trigger.linkBack = $0
            trigger.linkBackTouched = true
          })
      )
      .accessibilityIdentifier("automation-trigger-link-back")
      if let mcp {
        Toggle("Use the \(mcp.title) MCP", isOn: $usesMcp)
          .disabled(!mcp.isConnected && !usesMcp)
          .accessibilityIdentifier("automation-trigger-mcp")
        if !mcp.isConnected {
          Text("Sign in to \(mcp.title) in Settings to add it.")
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      if !renderedPrompt.isEmpty {
        DisclosureGroup("Prompt each run sends") {
          Text(renderedPrompt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        Button("Edit as a prompt", action: editAsPrompt)
          .accessibilityIdentifier("automation-trigger-edit-prompt")
      }
    }
  }

  /// Switching events clears what the new event reads differently, through the core.
  private var eventSelection: Binding<String> {
    Binding(
      get: { trigger.event },
      set: { id in
        guard id != trigger.event else { return }
        if let switchEvent { switchEvent(id) } else { trigger.event = id }
      })
  }

  private func conditionRow(_ condition: Binding<AutomationTriggerCondition>) -> some View {
    let field = template.fields.first { $0.id == condition.wrappedValue.field }
    let operation = field?.operations.first { $0.id == condition.wrappedValue.operation }
    return HStack {
      Picker("And", selection: fieldSelection(condition)) {
        ForEach(fields) { Text($0.title).tag($0.id) }
      }
      .fixedSize()
      if let namePlaceholder = field?.namePlaceholder {
        TextField(
          "Field",
          text: Binding(
            get: { condition.wrappedValue.name ?? "" },
            set: { condition.wrappedValue.name = $0 }),
          prompt: Text(namePlaceholder)
        )
        .labelsHidden()
      }
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
        let field = template.fields.first { $0.id == id }
        condition.wrappedValue.operation = field?.operations.first?.id ?? ""
        condition.wrappedValue.name = field?.namePlaceholder == nil ? nil : ""
      })
  }
}

extension String {
  /// The string with its first letter uppercased: "in project" → "In project".
  fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
