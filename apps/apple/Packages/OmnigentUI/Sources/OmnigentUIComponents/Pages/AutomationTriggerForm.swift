import SwiftUI

/// One "and <field> <operator> <value>" row.
struct AutomationTriggerConditionRow: View {
  @Binding var condition: AutomationTriggerCondition
  let template: AutomationTriggerTemplate
  let fields: [AutomationTriggerTemplate.Field]
  let remove: () -> Void

  var body: some View {
    let field = template.fields.first { $0.id == condition.field }
    let operation = field?.operations.first { $0.id == condition.operation }
    HStack(spacing: Theme.Spacing.small) {
      Text("and").foregroundStyle(.secondary).frame(width: 32)
      Picker("Field", selection: fieldSelection) {
        ForEach(fields) { Text($0.title).tag($0.id) }
      }
      .labelsHidden()
      .fixedSize()
      if let namePlaceholder = field?.namePlaceholder {
        TextField(
          "Field name",
          text: Binding(get: { condition.name ?? "" }, set: { condition.name = $0 }),
          prompt: Text(namePlaceholder)
        )
        .frame(width: 130)
      }
      Picker("Comparison", selection: $condition.operation) {
        ForEach(field?.operations ?? []) { Text($0.title).tag($0.id) }
      }
      .labelsHidden()
      .fixedSize()
      if operation?.isValueless != true {
        TextField("Value", text: $condition.value, prompt: Text(field?.placeholder ?? ""))
          .labelsHidden()
      } else {
        Spacer(minLength: 0)
      }
      Button("Remove condition", systemImage: "xmark", action: remove)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("automation-trigger-remove-\(condition.id)")
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automation-trigger-condition-\(condition.id)")
  }

  /// Switching the field resets the comparison to that field's default.
  private var fieldSelection: Binding<String> {
    Binding(
      get: { condition.field },
      set: { id in
        guard id != condition.field else { return }
        condition.field = id
        let field = template.fields.first { $0.id == id }
        condition.operation = field?.operations.first?.id ?? ""
        condition.name = field?.namePlaceholder == nil ? nil : ""
        condition.value = ""
      })
  }
}

/// A small outlined tag whose explanation shows on hover and to VoiceOver, as the web's
/// `WarningTag`.
struct AutomationTag: View {
  let label: String
  let systemImage: String
  let message: String

  var body: some View {
    Label(label, systemImage: systemImage)
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
      .background(
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(AutomationStyle.mutedFill)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(ThemeColor.border)
      )
      .fixedSize()
      .help(message)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(label): \(message)")
  }
}

/// A trigger template's fields as form sections, for an iOS form: the Trigger section with what
/// the event does, its warnings, the event, scope, inline value, conditions and link-back; the
/// Instructions section with what each started session gets and the prompt it renders.
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

  private var copy: AutomationTriggerCopy {
    AutomationTriggerCopy(template: template, trigger: trigger)
  }

  var body: some View {
    Section {
      Picker("Event", selection: eventSelection) {
        ForEach(template.events) { Text($0.name).tag($0.id) }
      }
      .accessibilityIdentifier("automation-trigger-event")
      if template.scopeOperators.count > 1, copy.event?.isGroup != true {
        Picker(
          copy.scopeLabel.capitalizedFirst,
          selection: Binding(
            get: { trigger.scopeOperator ?? "is" }, set: { trigger.scopeOperator = $0 })
        ) {
          ForEach(template.scopeOperators) { Text($0.name).tag($0.id) }
        }
        .accessibilityIdentifier("automation-trigger-scope-operator")
      }
      HStack(spacing: Theme.Spacing.extraSmall) {
        if let prefix = copy.event?.scopePrefix, !prefix.isEmpty {
          Text(prefix).foregroundStyle(.secondary)
        }
        TextField(
          copy.scopeLabel.capitalizedFirst, text: $trigger.scope,
          prompt: Text(copy.event?.scopePlaceholder ?? template.scopePlaceholder)
        )
        .accessibilityIdentifier("automation-trigger-scope")
      }
      if let target = copy.event?.target {
        TextField(
          "\(target.word.capitalizedFirst) (\(target.label.lowercased()))",
          text: Binding(get: { trigger.target ?? "" }, set: { trigger.target = $0 }),
          prompt: Text(target.placeholder)
        )
        .accessibilityIdentifier("automation-trigger-target")
        if copy.targetMissing, let hint = target.hint {
          Text(hint).font(.callout).foregroundStyle(.secondary)
        }
      }
      ForEach($trigger.conditions) { $condition in
        AutomationTriggerConditionRow(
          condition: $condition, template: template, fields: copy.fields,
          remove: { trigger.conditions.removeAll { $0.id == condition.id } })
      }
      if let first = copy.fields.first, let operation = first.operations.first {
        Button("Add condition", systemImage: "plus") {
          trigger.conditions.append(
            AutomationTriggerCondition(field: first.id, operation: operation.id))
        }
        .accessibilityIdentifier("automation-trigger-add-condition")
      }
      if copy.hasIncompleteCondition {
        Text("Fill in or remove each condition.").font(.callout).foregroundStyle(.secondary)
      }
      Toggle(template.linkBackLabel, isOn: linkBack)
        .accessibilityIdentifier("automation-trigger-link-back")
      if let mcp {
        Toggle("Use the \(mcp.title) MCP", isOn: $usesMcp)
          .disabled(!mcp.isConnected && !usesMcp)
          .accessibilityIdentifier("automation-trigger-mcp")
      }
    } header: {
      Text("Trigger")
    } footer: {
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Text(copy.summary).accessibilityIdentifier("automation-trigger-description")
        Text(mcp == nil ? copy.toolsWarning : mcpNote)
        Text(copy.sourceWarning)
      }
    }
    Section("Instructions") {
      TextField(
        copy.instructionsLabel, text: $trigger.instructions,
        prompt: Text(template.instructionsPlaceholder), axis: .vertical
      )
      .lineLimit(6...12)
      .accessibilityIdentifier("automation-trigger-instructions")
      if copy.instructionsTooLong {
        Text(copy.tooLongMessage).font(.callout).foregroundStyle(Theme.failure)
          .accessibilityIdentifier("automation-trigger-instructions-limit")
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

  private var mcpNote: String {
    guard let mcp else { return "" }
    if usesMcp {
      return "Every run, and each session it starts, uses your \(mcp.title) MCP service."
    }
    return mcp.isConnected
      ? "Runs only work if the agent can reach \(mcp.title)."
      : "Sign in to \(mcp.title) in Settings to add it."
  }

  private var linkBack: Binding<Bool> {
    Binding(
      get: { trigger.linkBack },
      set: {
        trigger.linkBack = $0
        trigger.linkBackTouched = true
      })
  }

  private var eventSelection: Binding<String> {
    Binding(
      get: { trigger.event },
      set: { id in
        guard id != trigger.event else { return }
        if let switchEvent { switchEvent(id) } else { trigger.event = id }
      })
  }
}

extension String {
  /// The string with its first letter uppercased: "in project" → "In project".
  fileprivate var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
