import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents

/// Maps the core's Jira, Slack and GitHub trigger templates to the editor and back.
enum AutomationTriggerMapping {
  /// The chips the Automations page offers, in the web's order.
  static var chips: [AutomationTriggerChip] {
    triggerSources().map { source in
      AutomationTriggerChip(
        id: id(source), title: triggerTemplate(source: source).title,
        systemImage: systemImage(source))
    }
  }

  /// The source of a chip or draft id.
  static func source(_ id: String) -> TriggerSource? {
    triggerSources().first { self.id($0) == id }
  }

  /// A new automation watching `source`: the template's name and default event, an hourly
  /// schedule and one continuing session, as the web opens a trigger.
  static func newDraft(_ source: TriggerSource, base: AutomationDraftState) -> AutomationDraftState
  {
    let template = triggerTemplate(source: source)
    let fields = emptyTriggerFields(source: source)
    var draft = base
    draft.name = template.name
    draft.prompt = ""
    draft.continuesSession = true
    draft.schedule = ScheduleChoice(preset: .hourly)
    draft.trigger = AutomationTriggerDraft(source: id(source), event: fields.event)
    draft.trigger?.linkBack = fields.linkBack
    return draft
  }

  /// The editor's view of `source`'s template.
  static func template(_ source: TriggerSource) -> AutomationTriggerTemplate {
    let template = triggerTemplate(source: source)
    return AutomationTriggerTemplate(
      events: template.events.map { AutomationOption(id: $0.id, name: $0.label) },
      scopeLabel: template.scopeLabel, scopePlaceholder: template.scopePlaceholder,
      fields: template.fields.map { field in
        AutomationTriggerTemplate.Field(
          id: field.id, title: field.label,
          operations: field.operators.map {
            .init(id: operationID($0.operator), title: $0.label, isValueless: $0.isValueless)
          },
          placeholder: field.placeholder)
      },
      instructionsPlaceholder: template.instructionsPlaceholder,
      linkBackLabel: template.linkBackLabel,
      maxInstructions: Int(maxTriggerInstructionsChars()))
  }

  /// The core's fields for the editor's.
  static func fields(_ draft: AutomationTriggerDraft) -> TriggerFields {
    TriggerFields(
      event: draft.event, scope: draft.scope,
      conditions: draft.conditions.map {
        TriggerCondition(field: $0.field, operator: operation($0.operation), value: $0.value)
      },
      instructions: draft.instructions, linkBack: draft.linkBack)
  }

  /// The prompt the trigger sends each run, or empty until its fields are complete.
  /// - Parameters:
  ///   - draft: The automation's fields.
  ///   - sessionLink: A session URL with the core's placeholder id; empty without a server URL.
  ///   - sendsOverrides: Whether the model and effort pass on to the workers.
  /// - Returns: The prompt.
  static func prompt(_ draft: AutomationDraftState, sessionLink: String, sendsOverrides: Bool)
    -> String
  {
    guard let trigger = draft.trigger, let source = source(trigger.source) else { return "" }
    let fields = fields(trigger)
    guard triggerFieldsComplete(fields: fields) else { return "" }
    let filled = { (value: String) in value.isEmpty || !sendsOverrides ? nil : value }
    return renderTriggerPrompt(
      source: source, fields: fields, inSandboxes: draft.runsInSandbox,
      sessionLink: sessionLink, model: filled(draft.model), effort: filled(draft.effort))
  }

  private static func id(_ source: TriggerSource) -> String {
    switch source {
    case .jira: "jira"
    case .slack: "slack"
    case .github: "github"
    }
  }

  private static func systemImage(_ source: TriggerSource) -> String {
    switch source {
    case .jira: "ticket"
    case .slack: "number"
    case .github: "smallcircle.filled.circle"
    }
  }

  private static let operations: [(String, TriggerOperator)] = [
    ("is", .is), ("is_not", .isNot), ("contains", .contains), ("not_contains", .notContains),
    ("about", .about), ("matches", .matches), ("empty", .empty), ("not_empty", .notEmpty),
  ]

  private static func operationID(_ operation: TriggerOperator) -> String {
    operations.first { $0.1 == operation }?.0 ?? "is"
  }

  private static func operation(_ id: String) -> TriggerOperator {
    operations.first { $0.0 == id }?.1 ?? .is
  }
}
