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

/// What a trigger watches, as the first row of its form: the service's mark in its brand color,
/// the event's first sentence with the rest under an info button, and the tags saying what a run
/// needs (the service's MCP) and what to trust.
struct AutomationTriggerHeader: View {
  let copy: AutomationTriggerCopy
  let source: String
  /// The source's own MCP service, when the catalog has one.
  var mcp: AutomationMcpOption?
  @Binding var usesMcp: Bool
  @State private var showsDetails = false

  var body: some View {
    HStack(alignment: .top, spacing: Theme.Spacing.medium) {
      Image(systemName: copy.template.systemImage)
        .font(.title3)
        .foregroundStyle(AutomationStyle.brandColor(source))
        .frame(width: 32, height: 32)
        .background(
          AutomationStyle.brandColor(source).opacity(0.12),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.extraSmall) {
          Text(copy.summary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("automation-trigger-description")
          Button("More trigger details", systemImage: "info.circle") { showsDetails.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
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
            label: "Untrusted source", systemImage: "exclamationmark.triangle.fill",
            message: copy.sourceWarning, tint: .orange
          )
          .accessibilityIdentifier("automation-trigger-untrusted")
        }
      }
    }
    .padding(.vertical, Theme.Spacing.extraSmall)
  }

  /// The service's MCP: used, offered to add, or needed.
  @ViewBuilder private var mcpTag: some View {
    if let mcp, usesMcp {
      AutomationTag(
        label: "Uses \(mcp.title) MCP", systemImage: "checkmark.circle.fill",
        message: "Every run, and each session it starts, uses your \(mcp.title) MCP service.",
        tint: .green
      )
      .accessibilityIdentifier("automation-trigger-mcp")
    } else if let mcp {
      Button("Add \(mcp.title) MCP", systemImage: "powerplug") { usesMcp = true }
        .controlSize(.small)
        .disabled(!mcp.isConnected)
        .help(
          mcp.isConnected
            ? "Runs only work if the agent can reach \(mcp.title). Add your \(mcp.title) MCP service, or give the agent its tools another way."
            : "Sign in to \(mcp.title) in Settings to add it."
        )
        .accessibilityIdentifier("automation-trigger-mcp")
    } else {
      AutomationTag(
        label: "MCP required", systemImage: "info.circle", message: copy.toolsWarning,
        tint: .secondary
      )
      .accessibilityIdentifier("automation-trigger-tools")
    }
  }
}
