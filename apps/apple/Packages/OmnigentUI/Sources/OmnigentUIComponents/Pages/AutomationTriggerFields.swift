import SwiftUI

/// What a trigger's form says, worded as the web's `TriggerTemplateFields`.
struct AutomationTriggerCopy {
  let template: AutomationTriggerTemplate
  let trigger: AutomationTriggerDraft

  /// The web's `MAX_SESSIONS_PER_RUN` and `OMNIGENT_ATTRIBUTION`.
  static let attribution =
    "Up to 10 matches per run; remaining matches wait for the next run \u{00B7} Posts include \u{201C}Sent with Omnigent\u{201D}."

  var event: AutomationTriggerTemplate.Event? { template.eventDetails[trigger.event] }

  /// The fields the event offers.
  var fields: [AutomationTriggerTemplate.Field] {
    let hidden = event?.hiddenFields ?? []
    return template.fields.filter { !hidden.contains($0.id) }
  }

  /// The description's first sentence, shown beside the mark.
  var summary: String {
    let description = event?.description ?? ""
    guard let end = description.range(of: ". ") else { return description }
    return String(description[..<end.lowerBound]) + "."
  }

  /// The rest of the description, under the info button.
  var details: String {
    let description = event?.description ?? ""
    guard let end = description.range(of: ". ") else { return Self.attribution }
    return "\(description[end.upperBound...])\n\n\(Self.attribution)"
  }

  var scopeLabel: String { event?.scopeLabel ?? template.scopeLabel }

  var toolsWarning: String {
    let tools = template.toolsExample.isEmpty ? "access to the service" : template.toolsExample
    return
      "This only works if the agent has \(tools) where this task runs. Without one, each run stops and says so in its reply."
  }

  var sourceWarning: String {
    let action = event?.authorAction.isEmpty == false ? event?.authorAction ?? "" : "add an item"
    let links =
      trigger.linkBack && !template.serviceName.isEmpty
      ? " Links are posted with your \(template.serviceName) account." : ""
    return
      "Anyone who can \(action) may direct the agent using your tools and permissions. Only use trusted sources.\(links)"
  }

  var instructionsTooLong: Bool { trigger.instructions.utf16.count > template.maxInstructions }

  var tooLongMessage: String {
    let recipient =
      trigger.taskSession ? "message to the task session" : "session\u{2019}s first message"
    let hint = template.budgetHint.map { " \($0)" } ?? ""
    return
      "Keep instructions to \(template.maxInstructions.formatted()) characters or fewer so each \(recipient) has room for the item.\(hint)"
  }

  var instructionsLabel: String {
    trigger.taskSession ? "Instructions for the task session" : "Instructions for each session"
  }

  /// A row with no value, or a custom field with no name, can't render the prompt.
  var hasIncompleteCondition: Bool {
    trigger.conditions.contains { condition in
      let field = template.fields.first { $0.id == condition.field }
      let operation = field?.operations.first { $0.id == condition.operation }
      let needsValue = operation?.isValueless != true
      let needsName = field?.namePlaceholder != nil
      return (needsValue && condition.value.trimmingCharacters(in: .whitespaces).isEmpty)
        || (needsName && (condition.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  var targetMissing: Bool {
    guard let target = event?.target, target.isRequired else { return false }
    return (trigger.target ?? "").trimmingCharacters(in: .whitespaces).isEmpty
  }
}

/// The trigger form's two panels, as the web's Trigger and Instructions tabs.
enum AutomationTriggerPanel: String, Hashable, CaseIterable, Identifiable {
  case trigger, instructions
  var id: Self { self }
}

/// A trigger template's fields, as the web lays them out: Trigger and Instructions tabs; the
/// Trigger tab a card with the service's mark, what the event does, its warnings, a sentence of
/// pickers ("Ticket created where project is ENG"), "and" condition rows and link-back; the
/// Instructions tab what each started session gets. The prompt they render can be taken over as
/// a plain prompt.
struct AutomationTriggerBuilder: View {
  @Binding var trigger: AutomationTriggerDraft
  let template: AutomationTriggerTemplate
  let renderedPrompt: String
  /// The source's own MCP service, when the catalog has one.
  var mcp: AutomationMcpOption?
  @Binding var usesMcp: Bool
  /// Switches the event, as the core's `trigger_fields_for_event`.
  var switchEvent: (@MainActor (String) -> Void)?
  let editAsPrompt: () -> Void
  @State private var panel: AutomationTriggerPanel = .trigger
  @State private var showsDetails = false

  private var copy: AutomationTriggerCopy {
    AutomationTriggerCopy(template: template, trigger: trigger)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      AutomationPillPicker(
        label: "Trigger setup", values: AutomationTriggerPanel.allCases, selection: $panel,
        title: panelTitle, identifier: { "automation-trigger-tab-\($0.rawValue)" })
      if copy.instructionsTooLong, panel != .instructions {
        HStack(spacing: Theme.Spacing.medium) {
          Text(copy.tooLongMessage).foregroundStyle(Theme.failure)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Button("Edit instructions") { panel = .instructions }.controlSize(.small)
        }
        .font(.callout)
        .accessibilityIdentifier("automation-trigger-too-long-notice")
      }
      switch panel {
      case .trigger: triggerCard
      case .instructions: instructions
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automation-trigger-fields")
  }

  private func panelTitle(_ panel: AutomationTriggerPanel) -> String {
    switch panel {
    case .trigger: "Trigger"
    case .instructions:
      trigger.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Instructions *" : (copy.instructionsTooLong ? "Instructions \u{26A0}" : "Instructions")
    }
  }

  private var triggerCard: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      header
      Divider()
      builder
      if copy.hasIncompleteCondition {
        Text("Fill in or remove each condition.").foregroundStyle(.secondary)
          .accessibilityIdentifier("automation-trigger-empty-condition")
      }
      Spacer(minLength: Theme.Spacing.small)
      Toggle(template.linkBackLabel, isOn: linkBack)
        #if os(macOS)
          .toggleStyle(.checkbox)
        #endif
        .font(.callout)
        .accessibilityIdentifier("automation-trigger-link-back")
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .strokeBorder(ThemeColor.border)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("automation-trigger-card")
  }

  /// The service's mark, what the event does with more under the info button, and the tags.
  private var header: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      Image(systemName: template.systemImage)
        .foregroundStyle(AutomationStyle.brandColor(trigger.source))
        .frame(width: 32, height: 32)
        .background(
          RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            .fill(AutomationStyle.brandColor(trigger.source).opacity(0.1))
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.extraSmall) {
          Text(copy.summary).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("automation-trigger-description")
          Button("More trigger details", systemImage: "info.circle") { showsDetails.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help(copy.details)
            .popover(isPresented: $showsDetails) {
              Text(copy.details).font(.callout).padding(Theme.Spacing.medium)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .presentationCompactAdaptation(.popover)
            }
            .accessibilityIdentifier("automation-trigger-details")
        }
        FlowLayout(spacing: Theme.Spacing.small) {
          mcpTag
          AutomationTag(
            label: "Untrusted source", systemImage: "exclamationmark.triangle",
            message: copy.sourceWarning
          )
          .accessibilityIdentifier("automation-trigger-untrusted")
        }
      }
    }
  }

  /// The service's MCP: used, offered to add, or needed.
  @ViewBuilder private var mcpTag: some View {
    if let mcp, usesMcp {
      AutomationTag(
        label: "Uses \(mcp.title) MCP", systemImage: "info.circle",
        message: "Every run, and each session it starts, uses your \(mcp.title) MCP service."
      )
      .accessibilityIdentifier("automation-trigger-mcp")
    } else if let mcp {
      Button {
        usesMcp = true
      } label: {
        Label("Add \(mcp.title) MCP", systemImage: "powerplug")
          .font(.caption)
          .padding(.horizontal, Theme.Spacing.small).padding(.vertical, Theme.Spacing.tiny)
          .foregroundStyle(Theme.warning)
          .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.warning.opacity(0.1))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .strokeBorder(Theme.warning.opacity(0.4)))
      }
      .buttonStyle(.plain)
      .disabled(!mcp.isConnected)
      .help(
        mcp.isConnected
          ? "Runs only work if the agent can reach \(mcp.title). Add your \(mcp.title) MCP service, or give the agent its tools another way."
          : "Sign in to \(mcp.title) in Settings to add it."
      )
      .accessibilityIdentifier("automation-trigger-mcp")
    } else {
      AutomationTag(label: "MCP required", systemImage: "info.circle", message: copy.toolsWarning)
        .accessibilityIdentifier("automation-trigger-tools")
    }
  }

  /// The sentence of pickers, its hints, and the condition rows.
  private var builder: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      FlowLayout(spacing: Theme.Spacing.small) {
        if template.events.count > 1 {
          Picker("Event", selection: eventSelection) {
            ForEach(template.events) { Text($0.name).tag($0.id) }
          }
          .labelsHidden().fixedSize()
          .accessibilityIdentifier("automation-trigger-event")
        } else if let event = template.events.first {
          Text(event.name).foregroundStyle(Theme.accent)
            .accessibilityIdentifier("automation-trigger-event")
        }
        if let target = copy.event?.target {
          Text(target.word).foregroundStyle(.secondary)
          TextField(
            target.label,
            text: Binding(get: { trigger.target ?? "" }, set: { trigger.target = $0 }),
            prompt: Text(target.placeholder)
          )
          .frame(width: 130)
          .accessibilityIdentifier("automation-trigger-target")
        }
        Text("where \(copy.scopeLabel)").foregroundStyle(.secondary)
        if template.scopeOperators.count > 1, copy.event?.isGroup != true {
          Picker(
            "Scope operator",
            selection: Binding(
              get: { trigger.scopeOperator ?? "is" }, set: { trigger.scopeOperator = $0 })
          ) {
            ForEach(template.scopeOperators) { Text($0.name).tag($0.id) }
          }
          .labelsHidden().fixedSize()
          .accessibilityIdentifier("automation-trigger-scope-operator")
        }
        HStack(spacing: Theme.Spacing.extraSmall) {
          if let prefix = copy.event?.scopePrefix, !prefix.isEmpty {
            Text(prefix).fontWeight(.medium).foregroundStyle(Theme.accent)
          }
          TextField(
            copy.scopeLabel, text: $trigger.scope,
            prompt: Text(copy.event?.scopePlaceholder ?? template.scopePlaceholder)
          )
          .frame(width: 180)
          .accessibilityIdentifier("automation-trigger-scope")
        }
      }
      if copy.targetMissing, let hint = copy.event?.target?.hint {
        Text(hint).foregroundStyle(.secondary)
          .accessibilityIdentifier("automation-trigger-target-hint")
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
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.leading, 40)
        .accessibilityIdentifier("automation-trigger-add-condition")
      }
    }
  }
}

/// The Instructions tab, and the bindings the Trigger tab writes through.
extension AutomationTriggerBuilder {
  /// What each started session gets, with the prompt it renders.
  private var instructions: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      TextField(
        copy.instructionsLabel, text: $trigger.instructions,
        prompt: Text(template.instructionsPlaceholder), axis: .vertical
      )
      .textFieldStyle(.plain)
      .lineLimit(10...)
      .padding(Theme.Spacing.medium)
      .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
      .overlay(
        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
          .strokeBorder(ThemeColor.border)
      )
      .accessibilityIdentifier("automation-trigger-instructions")
      if copy.instructionsTooLong {
        Text(copy.tooLongMessage).foregroundStyle(Theme.failure)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("automation-trigger-instructions-limit")
      }
      if !renderedPrompt.isEmpty {
        DisclosureGroup("Prompt each run sends") {
          Text(renderedPrompt).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .accessibilityIdentifier("automation-trigger-prompt-preview")
        Button("Edit as a prompt", action: editAsPrompt)
          .automationLinkStyle()
          .accessibilityIdentifier("automation-trigger-edit-prompt")
      }
    }
    .font(.callout)
  }

  private var linkBack: Binding<Bool> {
    Binding(
      get: { trigger.linkBack },
      set: {
        trigger.linkBack = $0
        trigger.linkBackTouched = true
      })
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
}
