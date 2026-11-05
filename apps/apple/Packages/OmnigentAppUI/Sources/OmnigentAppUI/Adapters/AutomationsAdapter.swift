import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The Automations page over ``PagesStore``: the list, its menu actions and the editor sheet.
struct AutomationsAdapter: View {
  let connection: ConnectionStore
  let open: (String) -> Void
  @State private var filter: AutomationsFilter = .all
  @State private var search = ""
  @State private var editing: Editing?
  @State private var draft = AutomationDraftState()
  @State private var isSaving = false
  @State private var saveError: String?

  /// The sheet's subject: a new automation, or the one with this id.
  private struct Editing: Identifiable {
    let id: String
    var automationID: String? { id.isEmpty ? nil : id }
  }

  var body: some View {
    if let pages = connection.pages {
      TimelineView(.periodic(from: .now, by: 60)) { context in
        AutomationsView(
          state: AutomationsMapping.state(
            pages: pages, filter: filter, search: search, now: context.date),
          actions: actions(pages))
      }
      .automationsIntro(connection)
      .task {
        await pages.loadAutomations()
        await pages.loadAutomationAgents()
      }
      .sheet(item: $editing) { target in
        AutomationEditorSheet(
          draft: $draft,
          context: AutomationEditorContext(
            agents: AutomationsMapping.agents(pages.automationAgents),
            supportsSessionModes: pages.offered?.automationSessionModes == true,
            describe: { AutomationsMapping.describe($0) },
            isEditing: target.automationID != nil, isSaving: isSaving,
            error: saveError ?? pages.automationAgents.error?.message),
          save: { save(pages, id: target.automationID) },
          cancel: { editing = nil })
      }
    } else {
      ContentUnavailableView("Automations are unavailable", systemImage: "clock")
    }
  }

  private func actions(_ pages: PagesStore) -> AutomationsActions {
    var actions = AutomationsActions()
    actions.filter = {
      filter = $0
      search = $1
    }
    actions.create = { suggestion in
      draft = AutomationsMapping.newDraft(suggestion, agents: pages.automationAgents.value ?? [])
      present(id: "")
    }
    actions.edit = { id in
      guard let automation = pages.automations.value?.first(where: { $0.id == id }) else { return }
      draft = AutomationsMapping.draft(automation)
      present(id: id)
    }
    actions.setPaused = { id, paused in Task { await pages.setAutomationPaused(id, paused) } }
    actions.runNow = { id in Task { await pages.runAutomation(id) } }
    actions.delete = { id in Task { await pages.deleteAutomation(id) } }
    actions.openSession = { open($0) }
    actions.retry = { Task { await pages.loadAutomations() } }
    actions.dismissError = { pages.dismissAutomationError() }
    return actions
  }

  private func present(id: String) {
    saveError = nil
    editing = Editing(id: id)
  }

  private func save(_ pages: PagesStore, id: String?) {
    guard !isSaving else { return }
    isSaving = true
    let existing = pages.automations.value?.first { $0.id == id }
    let request = AutomationsMapping.request(
      draft, keptRule: existing?.rrule,
      timezone: existing?.timezone ?? TimeZone.current.identifier,
      sessionModes: pages.offered?.automationSessionModes == true)
    Task {
      let saved = await pages.saveAutomation(request, editing: id)
      isSaving = false
      if saved {
        editing = nil
      } else {
        // The sheet shows the failure; the page banner would repeat it.
        saveError = pages.automationError?.message
        pages.dismissAutomationError()
      }
    }
  }
}

/// Maps automations between the core's records and the page's view state.
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
    return AutomationsViewState(
      rows: rows, hasAny: !all.isEmpty, isLoading: isLoading,
      loadError: pages.automations.error?.message, actionError: pages.automationError?.message)
  }

  static func agents(_ load: CreationLoad<[OmnigentCoreFFI.CreationAgent]>)
    -> [AutomationAgentChoice]
  {
    (load.value ?? []).filter(\.supportsCreation).map {
      AutomationAgentChoice(id: $0.id, name: $0.name)
    }
  }

  static func newDraft(_ suggestion: AutomationSuggestion?, agents: [OmnigentCoreFFI.CreationAgent])
    -> AutomationDraftState
  {
    AutomationDraftState(
      name: suggestion?.title ?? "", prompt: suggestion?.prompt ?? "",
      agentID: agents.first(where: \.supportsCreation)?.id ?? "",
      schedule: suggestion?.schedule ?? ScheduleChoice())
  }

  static func draft(_ automation: Automation) -> AutomationDraftState {
    let schedule = parseScheduleRrule(rrule: automation.rrule).map(choice)
    return AutomationDraftState(
      name: automation.name, prompt: automation.prompt, agentID: automation.agentId,
      schedule: schedule, keptRule: schedule == nil ? automation.scheduleText : nil,
      continuesSession: automation.continuesSession)
  }

  /// What to save. Without an editable schedule the edited automation's rule is kept as it is.
  /// - Parameters:
  ///   - draft: The editor's fields.
  ///   - keptRule: The edited automation's rule.
  ///   - timezone: The zone the rule runs in (the device's).
  ///   - sessionModes: Whether the server takes a session mode.
  /// - Returns: The draft the core saves.
  static func request(
    _ draft: AutomationDraftState, keptRule: String?, timezone: String, sessionModes: Bool
  ) -> AutomationDraft {
    AutomationDraft(
      name: draft.name, prompt: draft.prompt,
      rrule: draft.schedule.map { buildScheduleRrule(model: model($0)) } ?? keptRule ?? "",
      agentId: draft.agentID, timezone: timezone,
      continuesSession: sessionModes ? draft.continuesSession : nil)
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
      monthDays: choice.monthDays.map { UInt16(clamping: $0) }, month: UInt8(clamping: choice.month)
    )
  }

  static func choice(_ model: ScheduleModel) -> ScheduleChoice {
    ScheduleChoice(
      preset: preset(model.preset), hour: Int(model.hour), minute: Int(model.minute),
      weekdays: Set(model.weekdays.map(\.index)), frequency: frequency(model.frequency),
      interval: Int(model.interval), monthDays: model.monthDays.map(Int.init),
      month: Int(model.month))
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
