import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents

/// Maps the core's Jira, Slack, GitHub, Linear and PagerDuty trigger templates to the editor and
/// back: the gallery cards, the form, the config a header saves, and the prompt it renders.
enum AutomationTriggerMapping {
  /// The template cards the Automations page offers, in the web's order.
  static var cards: [AutomationTemplateCard] {
    triggerSources().map { source in
      let template = triggerTemplate(source: source)
      return AutomationTemplateCard(
        id: id(source), title: template.title, description: template.description,
        requirement: "Requires \(template.toolsExample).",
        systemImage: AutomationTemplateCard.symbol(forSource: id(source)))
    }
  }

  /// The integrations the editor's Trigger type offers, by their service names.
  static var types: [AutomationOption] {
    triggerSources().map { AutomationOption(id: id($0), name: serviceName($0)) }
  }

  /// `draft` switched to watch the integration `id`, or back to a schedule with `nil`, as the
  /// web's Trigger type: each type's fields are kept in `kept` and come back when it is chosen
  /// again; a name the user typed and the instructions carry over to a type chosen first.
  static func switchedType(
    _ draft: AutomationDraftState, to id: String?, kept: inout [String: AutomationDraftState],
    offered: ServerPages?
  ) -> AutomationDraftState {
    let current = draft.trigger?.source ?? scheduleType
    let target = id ?? scheduleType
    guard current != target else { return draft }
    kept[current] = draft
    let typedName =
      !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
      && draft.name != defaultName(current)
    let instructions = draft.trigger?.instructions ?? draft.prompt
    var next = draft
    if let saved = kept[target] {
      next.name = saved.name
      next.prompt = saved.prompt
      next.systemPrompt = saved.systemPrompt
      next.trigger = saved.trigger
      next.isTrigger = saved.isTrigger
      next.schedule = saved.schedule
      next.continuesSession = saved.continuesSession
    } else if let id, let source = source(id) {
      let schedule = AutomationsMapping.triggerSchedule(
        offered, continuesSession: true, inSandbox: draft.runsInSandbox)
      next = newDraft(source, base: draft, schedule: schedule)
      next.trigger?.instructions = instructions
      if typedName { next.name = draft.name }
    } else {
      next.trigger = nil
      next.isTrigger = false
      next.systemPrompt = nil
      next.prompt = instructions
      next.schedule = ScheduleChoice()
      next.continuesSession = false
      next.name = typedName ? draft.name : ""
    }
    return next
  }

  private static let scheduleType = "schedule"

  /// The name a new automation watching `id` starts with; empty for a schedule.
  static func defaultName(_ id: String) -> String {
    source(id).map { triggerTemplate(source: $0).name } ?? ""
  }

  /// The source of a card or draft id.
  static func source(_ id: String) -> TriggerSource? {
    triggerSources().first { self.id($0) == id }
  }

  /// A new automation watching `source`: the template's name and default event, the polling
  /// schedule and one continuing session, as the web opens a trigger.
  static func newDraft(
    _ source: TriggerSource, base: AutomationDraftState, schedule: ScheduleChoice
  )
    -> AutomationDraftState
  {
    var draft = base
    draft.name = triggerTemplate(source: source).name
    draft.prompt = ""
    draft.continuesSession = true
    draft.isTrigger = true
    draft.schedule = schedule
    draft.trigger = trigger(source, fields: emptyTriggerFields(source: source))
    return draft
  }

  /// The editor's draft of a saved trigger's header, as the form reopens it; where the server
  /// runs `workflows`, instructions that run a saved workflow reopen as its Workflow.
  static func editDraft(
    _ config: TriggerConfig, base: AutomationDraftState, workflows: Bool = false
  ) -> AutomationDraftState {
    var draft = base
    draft.prompt = ""
    draft.systemPrompt = nil
    draft.isTrigger = true
    var trigger = trigger(config.source, fields: config.fields)
    trigger.taskSession = config.taskSession
    trigger.worker = AutomationTriggerWorker(
      inSandboxes: config.worker.placement == .managed, agentID: config.worker.agentId,
      model: config.worker.model, effort: config.worker.effort,
      permissionMode: config.worker.permissionMode)
    if workflows {
      trigger.instructions = AutomationsMapping.openWorkflow(trigger.instructions, in: &draft)
    }
    draft.trigger = trigger
    return draft
  }

  /// The editor's fields for the core's.
  static func trigger(_ source: TriggerSource, fields: TriggerFields) -> AutomationTriggerDraft {
    var trigger = AutomationTriggerDraft(source: id(source), event: fields.event)
    trigger.scope = fields.scope
    trigger.scopeOperator = fields.scopeOperator.map(scopeOperatorID)
    trigger.conditions = fields.conditions.map {
      var row = AutomationTriggerCondition(field: $0.field, operation: operationID($0.operator))
      row.value = $0.value
      row.name = $0.name
      return row
    }
    trigger.target = fields.target
    trigger.instructions = fields.instructions
    trigger.linkBack = fields.linkBack
    trigger.linkBackTouched = fields.linkBackTouched == true
    return trigger
  }

  /// The core's fields for the editor's.
  static func fields(_ draft: AutomationTriggerDraft) -> TriggerFields {
    TriggerFields(
      event: draft.event, scope: draft.scope,
      scopeOperator: draft.scopeOperator.flatMap(scopeOperator),
      conditions: draft.conditions.map {
        TriggerCondition(
          field: $0.field, operator: operation($0.operation), value: $0.value, name: $0.name)
      },
      target: draft.target, instructions: draft.instructions, linkBack: draft.linkBack,
      linkBackTouched: draft.linkBackTouched ? true : nil)
  }

  /// `draft` switched to the event `eventID`, as the core clears what it reads differently.
  static func switched(_ draft: AutomationTriggerDraft, toEvent eventID: String)
    -> AutomationTriggerDraft
  {
    guard let source = source(draft.source) else { return draft }
    var next = trigger(
      source, fields: triggerFieldsForEvent(source: source, fields: fields(draft), eventId: eventID)
    )
    next.taskSession = draft.taskSession
    next.worker = draft.worker
    return next
  }

  /// The editor's view of `source`'s template within `budget`.
  static func template(_ source: TriggerSource, budget: TriggerMessageBudget)
    -> AutomationTriggerTemplate
  {
    let template = triggerTemplate(source: source)
    var view = AutomationTriggerTemplate(
      events: template.events.map { AutomationOption(id: $0.id, name: $0.label) },
      scopeLabel: template.scopeLabel, scopePlaceholder: template.scopePlaceholder,
      fields: template.fields.map { field in
        AutomationTriggerTemplate.Field(
          id: field.id, title: field.label,
          operations: field.operators.map {
            .init(id: operationID($0.operator), title: $0.label, isValueless: $0.isValueless)
          },
          placeholder: field.placeholder, namePlaceholder: field.namePlaceholder)
      },
      instructionsPlaceholder: template.instructionsPlaceholder,
      linkBackLabel: template.linkBackLabel,
      maxInstructions: Int(budget.instructionsMaxChars))
    view.eventDetails = Dictionary(
      template.events.map { event in
        (
          event.id,
          AutomationTriggerTemplate.Event(
            description: event.description, scopeLabel: event.scopeLabel,
            scopePlaceholder: event.scopePlaceholder, scopePrefix: event.scopePrefix,
            isGroup: event.scopeIsGroup, hiddenFields: event.hiddenFields,
            target: event.target.map {
              .init(
                word: $0.word, label: $0.label, placeholder: $0.placeholder, hint: $0.hint,
                isRequired: $0.required)
            }, authorAction: event.authorAction)
        )
      }, uniquingKeysWith: { first, _ in first })
    view.scopeOperators = template.scopeOperators.map {
      AutomationOption(id: scopeOperatorID($0.operator), name: $0.label)
    }
    view.budgetHint = budget.upgradeHint
    view.serviceName = template.serviceName
    view.toolsExample = template.toolsExample
    view.systemImage = AutomationTemplateCard.symbol(forSource: id(source))
    return view
  }

  /// What the trigger form saves for `draft`, or `nil` until its fields are complete. A saved
  /// trigger keeps its workers; a new one's follow the automation's settings, as the web's.
  /// - Parameters:
  ///   - draft: The automation's fields.
  ///   - budget: How long its instructions may be.
  ///   - workerPermissionMode: The permission a new trigger's workers start in, if any.
  ///   - sendsOverrides: Whether the model and effort pass on to new workers.
  /// - Returns: The config, or `nil` while the fields are incomplete.
  static func config(
    _ draft: AutomationDraftState, budget: TriggerMessageBudget, workerPermissionMode: String,
    sendsOverrides: Bool
  ) -> TriggerConfig? {
    guard let trigger = draft.trigger, let source = source(trigger.source) else { return nil }
    let fields = fields(trigger)
    guard
      triggerFieldsComplete(
        source: source, fields: fields, instructionsMaxChars: budget.instructionsMaxChars)
    else { return nil }
    let worker =
      trigger.worker.map {
        TriggerWorker(
          placement: $0.inSandboxes ? .managed : .sameHost, agentId: $0.agentID, model: $0.model,
          effort: $0.effort, permissionMode: $0.permissionMode)
      }
      ?? TriggerWorker(
        placement: draft.runsInSandbox ? .managed : .sameHost, agentId: nil,
        model: sendsOverrides ? draft.model : "", effort: sendsOverrides ? draft.effort : "",
        permissionMode: workerPermissionMode)
    return TriggerConfig(
      source: source, fields: fields, taskSession: trigger.taskSession, worker: worker)
  }

  /// The prompt a trigger saves: the header and manager prompt on a server that drops the
  /// header before dispatch, else the manager prompt alone; empty until the fields complete.
  static func prompt(
    _ config: TriggerConfig?, context: TriggerConfigContext, withHeader: Bool
  ) -> String {
    guard let config else { return "" }
    return withHeader
      ? encodeTriggerPrompt(config: config, context: context)
      : renderTriggerConfigPrompt(config: config, context: context)
  }

  /// What a saved config doesn't hold: the link, polling interval, task-session title and
  /// message budget.
  static func context(
    _ draft: AutomationDraftState, sessionLink: String, budget: TriggerMessageBudget
  ) -> TriggerConfigContext {
    // The first run looks back over the wait until the first poll.
    var polling: UInt32 = 60
    if let schedule = draft.schedule,
      schedule.preset == .interval
        || (schedule.preset == .custom && schedule.frequency == .minutely)
    {
      polling = UInt32(clamping: schedule.interval)
    }
    return TriggerConfigContext(
      sessionLink: sessionLink, pollingIntervalMinutes: polling, taskSessionTitle: draft.name,
      messageMaxChars: budget.messageMaxChars)
  }

  static func id(_ source: TriggerSource) -> String {
    switch source {
    case .jira: "jira"
    case .slack: "slack"
    case .github: "github"
    case .linear: "linear"
    case .pagerDuty: "pagerduty"
    }
  }

  /// The service's display name, e.g. "PagerDuty".
  static func serviceName(_ source: TriggerSource) -> String {
    triggerTemplate(source: source).serviceName
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

  private static let scopeOperators: [(String, TriggerScopeOperator)] = [
    ("is", .is), ("in", .in), ("contains", .contains),
  ]

  private static func scopeOperatorID(_ operation: TriggerScopeOperator) -> String {
    scopeOperators.first { $0.1 == operation }?.0 ?? "is"
  }

  private static func scopeOperator(_ id: String) -> TriggerScopeOperator? {
    scopeOperators.first { $0.0 == id }?.1
  }
}
