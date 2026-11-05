import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Maps automations between the core's records and the list, editor and schedule view state.
enum AutomationsMapping {
  static func state(pages: PagesStore, filter: AutomationsFilter, search: String, now: Date)
    -> AutomationsViewState
  {
    let all = pages.automations.value ?? []
    let arranged = arrangeAutomations(automations: all, filter: filter.core, search: search)
    let seconds = Int64(now.timeIntervalSince1970)
    let rows = arranged.map { automation in
      var row = AutomationRow(
        id: automation.id, name: automation.name, scheduleText: automation.scheduleText,
        nextRunText: automation.nextRunAt.map { formatNextRun(nextRunAt: $0, now: seconds) },
        isPaused: automation.state == .paused)
      if case .unknown(let value) = automation.state {
        row.scheduleText += " \u{00B7} \(value.capitalized)"
      }
      row.isBusy = pages.busyAutomationIDs.contains(automation.id)
      row.lastRunSessionID = automation.lastRunSessionId
      return row
    }
    let isLoading = if case .loading = pages.automations { true } else { false }
    var state = AutomationsViewState(
      rows: rows, hasAny: !all.isEmpty, isLoading: isLoading,
      loadError: pages.automations.error?.message, actionError: pages.automationError?.message)
    if pages.offered?.automationTriggers == true {
      state.triggers = AutomationTriggerMapping.chips
    }
    return state
  }

  /// The agents the editor offers: those this app can start sessions for.
  static func agents(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> [AutomationOption] {
    (catalog?.agents ?? []).filter(\.supportsCreation).map {
      AutomationOption(id: $0.id, name: $0.name)
    }
  }

  /// A new automation: a suggestion's fields, the first agent that can start sessions, and the
  /// first online host, as the web's dialog starts.
  static func newDraft(
    _ suggestion: AutomationSuggestion?, catalog: OmnigentCoreFFI.CreationCatalog?
  )
    -> AutomationDraftState
  {
    var draft = AutomationDraftState(
      name: suggestion?.title ?? "", prompt: suggestion?.prompt ?? "",
      agentID: catalog?.agents.first(where: \.supportsCreation)?.id ?? "",
      schedule: suggestion?.schedule ?? ScheduleChoice())
    draft.hostID = catalog?.hosts.first { $0.status == "online" }?.hostId ?? ""
    return draft
  }

  static func draft(_ automation: Automation) -> AutomationDraftState {
    let schedule = parseScheduleRrule(rrule: automation.rrule).map(choice)
    var draft = AutomationDraftState(
      name: automation.name, prompt: automation.prompt, agentID: automation.agentId,
      schedule: schedule, keptRule: schedule == nil ? automation.scheduleText : nil,
      continuesSession: automation.continuesSession)
    draft.hostID = automation.hostId ?? ""
    draft.workspace = automation.workspace ?? ""
    draft.runsInSandbox = automation.runsInSandbox
    draft.projectID = automation.projectId ?? ""
    restoreOverrides(&draft, from: automation)
    return draft
  }

  /// Puts back `automation`'s model, effort and permission mode, as the editor opened with.
  static func restoreOverrides(_ draft: inout AutomationDraftState, from automation: Automation?) {
    draft.model = automation?.modelOverride ?? ""
    draft.effort = automation?.reasoningEffort ?? ""
    draft.permissionMode = automation?.permissionMode ?? ""
  }

  /// What to save. Without an editable schedule the edited automation's rule is kept as it is.
  /// - Parameters:
  ///   - draft: The editor's fields.
  ///   - prompt: The prompt to send: the draft's, or its trigger's rendered one.
  ///   - saved: The automation being edited.
  ///   - sessionModes: Whether the server takes a session mode.
  ///   - sendsOverrides: Whether the agent takes a model, effort and permission mode.
  /// - Returns: The draft the core saves.
  static func request(
    _ draft: AutomationDraftState, prompt: String, saved: Automation?, sessionModes: Bool,
    sendsOverrides: Bool
  ) -> AutomationDraft {
    let filled = { (text: String) -> String? in
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    return AutomationDraft(
      name: draft.name, prompt: prompt,
      rrule: draft.schedule.map { buildScheduleRrule(model: model($0)) } ?? saved?.rrule ?? "",
      agentId: draft.agentID, timezone: saved?.timezone ?? TimeZone.current.identifier,
      continuesSession: sessionModes ? draft.continuesSession : nil,
      hostId: filled(draft.hostID), workspace: filled(draft.workspace),
      runsInSandbox: draft.runsInSandbox, projectId: filled(draft.projectID),
      sendsOverrides: sendsOverrides, modelOverride: filled(draft.model),
      reasoningEffort: filled(draft.effort), permissionMode: filled(draft.permissionMode),
      startNewSession: draft.startNewSession)
  }

  /// Why the draft's schedule can't be saved, in the web's words.
  /// - Parameters:
  ///   - schedule: The schedule; `nil` keeps the saved rule, which is always allowed.
  ///   - saved: The automation being edited, whose unchanged rule may keep a past end.
  ///   - anchored: The server runs custom schedules and run-count endings.
  ///   - now: The current time.
  /// - Returns: The problem, or `nil`.
  static func scheduleProblem(
    _ schedule: ScheduleChoice?, saved: Automation?, anchored: Bool, now: Date
  ) -> String? {
    guard let schedule else { return nil }
    let rule = model(schedule)
    if !anchored, scheduleNeedsAnchoredScheduling(model: rule) {
      return
        "This server does not support custom schedules or occurrence limits. Choose a supported frequency and ending to replace this schedule."
    }
    let unchanged = saved.map { $0.rrule == buildScheduleRrule(model: rule) } ?? false
    return validateSchedule(
      model: rule, now: Int64(now.timeIntervalSince1970), allowPastEnd: unchanged)
  }

  static func describe(_ choice: ScheduleChoice) -> String {
    describeSchedule(rrule: buildScheduleRrule(model: model(choice)))
  }

  static func model(_ choice: ScheduleChoice) -> ScheduleModel {
    ScheduleModel(
      preset: preset(choice.preset), hour: UInt8(clamping: choice.hour),
      minute: UInt8(clamping: choice.minute),
      weekdays: choice.weekdays.sorted().compactMap { Weekday(index: $0) },
      frequency: frequency(choice.frequency), interval: UInt16(clamping: choice.interval),
      monthDays: choice.monthDays.map { UInt16(clamping: $0) },
      month: UInt8(clamping: choice.month), end: end(choice.end))
  }

  static func choice(_ model: ScheduleModel) -> ScheduleChoice {
    ScheduleChoice(
      preset: preset(model.preset), hour: Int(model.hour), minute: Int(model.minute),
      weekdays: Set(model.weekdays.map(\.index)), frequency: frequency(model.frequency),
      interval: Int(model.interval), monthDays: model.monthDays.map(Int.init),
      month: Int(model.month), end: end(model.end))
  }

  private static func end(_ end: ScheduleChoice.End) -> ScheduleEnd {
    switch end {
    case .never: .never
    case .count(let count): .count(count: UInt32(clamping: count))
    case .until(let date): .until(at: Int64(date.timeIntervalSince1970))
    }
  }

  private static func end(_ end: ScheduleEnd) -> ScheduleChoice.End {
    switch end {
    case .never: .never
    case .count(let count): .count(Int(count))
    case .until(let seconds): .until(Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
  }

  private static func preset(_ preset: ScheduleChoice.Preset) -> SchedulePreset {
    switch preset {
    case .hourly: .hourly
    case .daily: .daily
    case .weekdays: .weekdays
    case .weekly: .weekly
    case .custom: .custom
    }
  }

  private static func preset(_ preset: SchedulePreset) -> ScheduleChoice.Preset {
    switch preset {
    case .hourly: .hourly
    case .daily: .daily
    case .weekdays: .weekdays
    case .weekly: .weekly
    case .custom: .custom
    }
  }

  private static func frequency(_ frequency: ScheduleChoice.Frequency) -> ScheduleFrequency {
    switch frequency {
    case .hourly: .hourly
    case .daily: .daily
    case .weekly: .weekly
    case .monthly: .monthly
    case .yearly: .yearly
    }
  }

  private static func frequency(_ frequency: ScheduleFrequency) -> ScheduleChoice.Frequency {
    switch frequency {
    case .hourly: .hourly
    case .daily: .daily
    case .weekly: .weekly
    case .monthly: .monthly
    case .yearly: .yearly
    }
  }
}

extension Weekday {
  private static let ordered: [Weekday] = [
    .monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday,
  ]

  /// Monday = 0, as the schedule editor counts.
  init?(index: Int) {
    guard Self.ordered.indices.contains(index) else { return nil }
    self = Self.ordered[index]
  }

  /// Monday = 0.
  var index: Int { Self.ordered.firstIndex(of: self) ?? 0 }
}

extension AutomationsFilter {
  fileprivate var core: AutomationFilter {
    switch self {
    case .all: .all
    case .active: .active
    case .paused: .paused
    }
  }
}
