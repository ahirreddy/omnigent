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
    let rows = arranged.map { row($0, pages: pages, now: now) }
    let isLoading = if case .loading = pages.automations { true } else { false }
    var state = AutomationsViewState(
      rows: rows, hasAny: !all.isEmpty, isLoading: isLoading,
      loadError: pages.automations.error?.message, actionError: pages.automationError?.message)
    if pages.offered?.automationTriggers == true {
      state.templates = AutomationTriggerMapping.cards
    }
    if pages.offered?.automationSharedWithMe == true {
      state.shared = shared(pages: pages, filter: filter, search: search, now: now)
    }
    return state
  }

  /// The Shared with me tab, read-only rows a page at a time.
  static func shared(pages: PagesStore, filter: AutomationsFilter, search: String, now: Date)
    -> SharedAutomationsState
  {
    let all = pages.sharedAutomations.value ?? []
    var shared = SharedAutomationsState()
    shared.rows = arrangeAutomations(automations: all, filter: filter.core, search: search).map {
      row($0, pages: pages, now: now)
    }
    shared.hasAny = !all.isEmpty
    shared.isLoading = pages.sharedAutomations == .loading || pages.sharedAutomations == .idle
    shared.loadError = pages.sharedAutomations.error?.message
    shared.hasMore = pages.sharedAutomationsCursor != nil
    shared.isLoadingMore = pages.isLoadingMoreSharedAutomations
    return shared
  }

  /// One card: its schedule or trigger line, last-run warning, owner, and whether it shares.
  static func row(_ automation: Automation, pages: PagesStore, now: Date) -> AutomationRow {
    let seconds = Int64(now.timeIntervalSince1970)
    var row = AutomationRow(
      id: automation.id, name: automation.name, scheduleText: automation.scheduleText,
      nextRunText: automation.nextRunAt.map { formatNextRun(nextRunAt: $0, now: seconds) },
      isPaused: automation.state == .paused)
    if case .unknown(let value) = automation.state {
      row.scheduleText += " \u{00B7} \(value.capitalized)"
    }
    row.isBusy = pages.busyAutomationIDs.contains(automation.id)
    row.lastRunSessionID = automation.lastRunSessionId
    row.lastRunFailed = automation.lastRunStatus == "failed"
    row.isTrigger = automation.isTrigger
    if automation.sharedWithMe {
      row.sharedBy = automation.ownerName
    } else if pages.offered?.automationSharing == true {
      row.canShare = true
      row.shareDisabledReason = ShareAdapter.unavailableReason(
        pages.offered, automation: automation)
    }
    return row
  }

  /// The agents the editor offers: those this app can start sessions for and the user has not
  /// hidden from the pickers, keeping `selectedID`.
  static func agents(
    _ catalog: OmnigentCoreFFI.CreationCatalog?, selectedID: String? = nil
  ) -> [AutomationOption] {
    let creatable = (catalog?.agents ?? []).filter(\.supportsCreation)
    return PickerVisibilityAdapter.shown(creatable, selectedID: selectedID).map {
      AutomationOption(id: $0.id, name: $0.name)
    }
  }

  /// A new automation: the first agent that can start sessions, in the mode an unattended run
  /// starts in, and the first online host, as the web's dialog starts.
  static func newDraft(catalog: OmnigentCoreFFI.CreationCatalog?) -> AutomationDraftState {
    let agent = catalog?.agents.first(where: \.supportsCreation)
    var draft = AutomationDraftState(agentID: agent?.id ?? "")
    draft.hostID = catalog?.hosts.first { $0.status == "online" }?.hostId ?? ""
    draft.permissionMode = AutomationEditorMapping.newAutomationPermission(agent)
    return draft
  }

  /// A new automation that runs `workflow` as saved (web `lockedWorkflow`): named for it, with a
  /// new session each run, as a workflow's runs need.
  static func workflowDraft(
    _ workflow: SavedWorkflow, catalog: OmnigentCoreFFI.CreationCatalog?
  ) -> AutomationDraftState {
    var draft = newDraft(catalog: catalog)
    draft.name = workflow.name
    draft.continuesSession = false
    let harness = catalog?.agents.first { $0.id == draft.agentID }?.harness
    draft.prompt = savedWorkflowMessage(
      skillPrefix: skillInvocationPrefix(harness: harness), workflowId: workflow.id,
      workflowName: workflow.name, details: "", reviewPlanFirst: false)
    return draft
  }

  /// A new trigger's schedule: the server's polling interval where the scheduler runs minute
  /// rules there, else hourly.
  static func triggerSchedule(_ offered: ServerPages?, continuesSession: Bool, inSandbox: Bool)
    -> ScheduleChoice
  {
    let hourly = ScheduleChoice(preset: .hourly)
    guard let offered, offered.automationsV2 else { return hourly }
    let minutes = Int(offered.automationTriggerPollMinutes)
    guard offered.automationSubhour || minutes >= 60 else { return hourly }
    let interval = ScheduleChoice(preset: .interval, frequency: .minutely, interval: minutes)
    let limits = ScheduleLimits(
      subhourSupported: offered.automationSubhour, continuesSession: continuesSession,
      onConnectedHost: !inSandbox)
    let problem = validateSchedule(
      model: model(interval), now: 0, allowPastEnd: true, limits: limits)
    return problem == nil ? interval : hourly
  }

  /// The editor's fields for `automation`. A trigger whose header reads back reopens in its
  /// form; an older one shows its instructions, keeping the text around them; a header edited
  /// outside the form opens the prompt the model runs.
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
    draft.maxCost = automation.maxCostUsd ?? ""
    draft.mcpServices = automation.mcpServices
    draft.sourceSessionID = automation.sourceSessionId
    draft.isTrigger = automation.isTrigger
    restoreOverrides(&draft, from: automation)
    if automation.isTrigger, let config = decodeTriggerPrompt(prompt: automation.prompt) {
      return AutomationTriggerMapping.editDraft(config, base: draft)
    }
    let withoutHeader = stripTriggerHeader(prompt: automation.prompt)
    if withoutHeader != automation.prompt {
      // A header that no longer matches its body: its rendered prompt is what runs.
      draft.prompt = withoutHeader
    } else {
      let parts = splitTriggerPrompt(prompt: automation.prompt)
      draft.prompt = parts.userPrompt
      draft.systemPrompt = parts.systemPrompt
    }
    return draft
  }

  /// Puts back `automation`'s model, effort and permission mode, as the editor opened with.
  static func restoreOverrides(_ draft: inout AutomationDraftState, from automation: Automation?) {
    draft.model = automation?.modelOverride ?? ""
    draft.effort = automation?.reasoningEffort ?? ""
    draft.permissionMode = automation?.permissionMode ?? ""
  }

  /// The prompt to save: a trigger's, the instructions put back into an older trigger's text,
  /// or the typed one.
  static func prompt(_ draft: AutomationDraftState, triggerPrompt: String) -> String {
    if draft.trigger != nil { return triggerPrompt }
    return combineTriggerPrompt(userPrompt: draft.prompt, systemPrompt: draft.systemPrompt)
  }

  /// What to save. Without an editable schedule the edited automation's rule is kept as it is.
  /// - Parameters:
  ///   - draft: The editor's fields.
  ///   - prompt: The prompt to send: the draft's, or its trigger's rendered one.
  ///   - saved: The automation being edited.
  ///   - sessionModes: Whether the server takes a session mode.
  ///   - sendsOverrides: Whether the agent takes a model, effort and permission mode.
  ///   - sendsMcpServices: Whether the server takes the runs' MCP services.
  /// - Returns: The draft the core saves.
  static func request(
    _ draft: AutomationDraftState, prompt: String, saved: Automation?, sessionModes: Bool,
    sendsOverrides: Bool, sendsMcpServices: Bool = false
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
      startNewSession: draft.startNewSession,
      mcpServices: sendsMcpServices ? draft.mcpServices : nil, maxCostUsd: draft.maxCost,
      sourceSessionId: saved == nil ? draft.sourceSessionID : nil)
  }

  /// What bounds a minute schedule for `draft` on this server.
  static func limits(_ draft: AutomationDraftState, offered: ServerPages?) -> ScheduleLimits {
    ScheduleLimits(
      subhourSupported: offered?.automationSubhour == true,
      continuesSession: draft.continuesSession, onConnectedHost: !draft.runsInSandbox)
  }

  /// Why the draft's schedule can't be saved, in the web's words.
  /// - Parameters:
  ///   - schedule: The schedule; `nil` keeps the saved rule, which is always allowed.
  ///   - saved: The automation being edited, whose unchanged rule may keep a past end.
  ///   - anchored: The server runs custom schedules and run-count endings.
  ///   - now: The current time.
  ///   - limits: What bounds a minute schedule here.
  /// - Returns: The problem, or `nil`.
  static func scheduleProblem(
    _ schedule: ScheduleChoice?, saved: Automation?, anchored: Bool, now: Date,
    limits: ScheduleLimits = ScheduleLimits(
      subhourSupported: true, continuesSession: true, onConnectedHost: true)
  ) -> String? {
    guard let schedule else { return nil }
    let rule = model(schedule)
    if !anchored, scheduleNeedsAnchoredScheduling(model: rule) {
      return
        "This server does not support custom schedules or occurrence limits. Choose a supported frequency and ending to replace this schedule."
    }
    let unchanged = saved.map { $0.rrule == buildScheduleRrule(model: rule) } ?? false
    return validateSchedule(
      model: rule, now: Int64(now.timeIntervalSince1970), allowPastEnd: unchanged, limits: limits)
  }

  static func describe(_ choice: ScheduleChoice) -> String {
    describeSchedule(rrule: buildScheduleRrule(model: model(choice)))
  }

  static func model(_ choice: ScheduleChoice) -> ScheduleModel {
    let interval = choice.preset == .interval
    return ScheduleModel(
      preset: interval ? .custom : preset(choice.preset), hour: UInt8(clamping: choice.hour),
      minute: UInt8(clamping: choice.minute),
      weekdays: choice.weekdays.sorted().compactMap { Weekday(index: $0) },
      frequency: interval ? .minutely : frequency(choice.frequency),
      interval: UInt16(clamping: choice.interval),
      monthDays: choice.monthDays.map { UInt16(clamping: $0) },
      month: UInt8(clamping: choice.month), end: end(choice.end))
  }

  /// The editor's choice for a rule; a saved minute rule reopens as Interval, as the web's.
  static func choice(_ model: ScheduleModel) -> ScheduleChoice {
    let minutes = model.preset == .custom && model.frequency == .minutely
    return ScheduleChoice(
      preset: minutes ? .interval : preset(model.preset), hour: Int(model.hour),
      minute: Int(model.minute), weekdays: Set(model.weekdays.map(\.index)),
      frequency: frequency(model.frequency), interval: Int(model.interval),
      monthDays: model.monthDays.map(Int.init), month: Int(model.month), end: end(model.end))
  }

  private static func end(_ end: ScheduleChoice.End) -> ScheduleEnd {
    switch end {
    case .never: .never
    case .count(let count): .count(count: UInt32(clamping: count))
    case .until(let date):
      .until(at: Int64(min(max(date.timeIntervalSince1970, -0x1p62), 0x1p62)))
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
    case .custom, .interval: .custom
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
    case .minutely: .minutely
    case .hourly: .hourly
    case .daily: .daily
    case .weekly: .weekly
    case .monthly: .monthly
    case .yearly: .yearly
    }
  }

  private static func frequency(_ frequency: ScheduleFrequency) -> ScheduleChoice.Frequency {
    switch frequency {
    case .minutely: .minutely
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
