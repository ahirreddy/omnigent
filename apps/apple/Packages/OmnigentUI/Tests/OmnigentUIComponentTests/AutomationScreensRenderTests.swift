#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Automation screens with hostile data", .serialized)
  struct AutomationScreensRenderTests {
    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("automations-realistic", realistic: true) {
        AutomationsView(state: PreviewData.automations, actions: everyListAction)
      },
      ScreenCase("automations-none-yet", realistic: true, narrowOnly: true) {
        AutomationsView(
          state: AutomationsViewState(rows: [], hasAny: false), actions: everyListAction)
      },
      ScreenCase("automations-none-match", narrowOnly: true) {
        AutomationsView(
          state: AutomationsViewState(rows: [], hasAny: true), actions: everyListAction)
      },
      ScreenCase("automations-loading", narrowOnly: true) {
        AutomationsView(
          state: AutomationsViewState(rows: [], hasAny: false, isLoading: true),
          actions: everyListAction)
      },
      ScreenCase("automations-load-error", narrowOnly: true) {
        AutomationsView(
          state: AutomationsViewState(rows: [], hasAny: true, loadError: HostileData.unbroken),
          actions: everyListAction)
      },
      ScreenCase("automations-hostile") {
        AutomationsView(state: hostileList, actions: everyListAction)
      },
      ScreenCase("automations-long-error", narrowOnly: true) {
        AutomationsView(
          state: AutomationsViewState(
            rows: [], hasAny: true, actionError: HostileData.unbroken), actions: everyListAction)
      },
      ScreenCase("automation-detail-realistic", realistic: true) {
        AutomationDetailView(state: realisticDetail, actions: everyDetailAction)
      },
      ScreenCase("automation-detail-blank", narrowOnly: true) {
        AutomationDetailView(state: detail(name: "", text: ""), actions: AutomationDetailActions())
      },
      ScreenCase("automation-detail-runs-loading", narrowOnly: true) {
        var state = realisticDetail
        state.isLoadingRuns = true
        return AutomationDetailView(state: state, actions: everyDetailAction)
      },
      ScreenCase("automation-detail-runs-error", narrowOnly: true) {
        var state = realisticDetail
        state.runsError = HostileData.unbroken
        return AutomationDetailView(state: state, actions: everyDetailAction)
      },
      ScreenCase("automation-detail-hostile") {
        AutomationDetailView(state: hostileDetail, actions: everyDetailAction)
      },
      ScreenCase("automation-detail-long-text", narrowOnly: true) {
        var state = detail(name: HostileData.unbroken, text: HostileData.unbroken)
        state.actionError = HostileData.unbroken
        return AutomationDetailView(state: state, actions: everyDetailAction)
      },
      ScreenCase("automation-editor-realistic", realistic: true) {
        AutomationEditorSheet(
          draft: .constant(
            AutomationDraftState(name: "Daily brief", prompt: "Summarize", agentID: "a1")),
          context: context(), save: {}, cancel: {})
      },
      ScreenCase("automation-editor-blank", narrowOnly: true) {
        AutomationEditorSheet(
          draft: .constant(AutomationDraftState()),
          context: AutomationEditorContext(
            agents: [], supportsSessionModes: false, describe: { _ in "" }), save: {}, cancel: {})
      },
      ScreenCase("automation-editor-kept-rule", narrowOnly: true) {
        AutomationEditorSheet(
          draft: .constant(
            AutomationDraftState(schedule: nil, keptRule: HostileData.unbroken)),
          context: context(editing: true), save: {}, cancel: {})
      },
      ScreenCase("automation-editor-sandbox", narrowOnly: true) {
        var draft = AutomationDraftState(name: "Sweep", prompt: "Go", agentID: "a1")
        draft.runsInSandbox = true
        draft.continuesSession = true
        return AutomationEditorSheet(
          draft: .constant(draft), context: context(editing: true), save: {}, cancel: {})
      },
      ScreenCase("automation-editor-hostile") {
        AutomationEditorSheet(
          draft: .constant(hostileDraft), context: hostileContext, save: {}, cancel: {})
      },
      ScreenCase("automation-editor-trigger", narrowOnly: true) {
        var editorContext = context()
        editorContext.trigger = triggerTemplate
        editorContext.triggerPrompt = HostileData.unbroken
        return AutomationEditorSheet(
          draft: .constant(triggerDraft(event: "created", condition: "assignee")),
          context: editorContext, save: {}, cancel: {})
      },
      // A trigger saved against an older template: its event and field no longer exist.
      ScreenCase("automation-editor-trigger-unknown-fields", narrowOnly: true) {
        var editorContext = context()
        editorContext.trigger = triggerTemplate
        return AutomationEditorSheet(
          draft: .constant(triggerDraft(event: "gone", condition: "gone")), context: editorContext,
          save: {}, cancel: {})
      },
      ScreenCase("schedule-custom-yearly-until-future", realistic: true) {
        GroupedFormHost {
          ScheduleFields(
            choice: .constant(
              ScheduleChoice(
                preset: .custom, frequency: .yearly, monthDays: [1, 15], month: 12,
                end: .until(.distantFuture))))
        }
      },
      ScreenCase("schedule-weekly-count", narrowOnly: true) {
        GroupedFormHost {
          ScheduleFields(
            choice: .constant(
              ScheduleChoice(preset: .weekly, weekdays: Set(0..<7), end: .count(9_999))))
        }
      },
      ScreenCase("schedule-hourly-unanchored", narrowOnly: true) {
        GroupedFormHost {
          ScheduleFields(
            choice: .constant(ScheduleChoice(preset: .hourly, minute: 59, end: .count(1))),
            anchoredScheduling: false)
        }
      },
      ScreenCase("schedule-out-of-range", narrowOnly: true) {
        GroupedFormHost { ScheduleFields(choice: .constant(outOfRangeSchedule)) }
      },
      ScreenCase("schedule-custom-monthly-negative-count", narrowOnly: true) {
        GroupedFormHost {
          ScheduleFields(
            choice: .constant(
              ScheduleChoice(
                preset: .custom, frequency: .monthly, interval: Int.max, monthDays: [-1, 0, 99],
                end: .count(-1))))
        }
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }
  }

  extension AutomationScreensRenderTests {
    private static var everyListAction: AutomationsActions {
      var actions = AutomationsActions()
      actions.filter = { _, _ in }
      actions.create = { _ in }
      actions.createTrigger = { _ in }
      actions.openDetail = { _ in }
      actions.edit = { _ in }
      actions.setPaused = { _, _ in }
      actions.runNow = { _ in }
      actions.delete = { _ in }
      actions.openSession = { _ in }
      actions.retry = {}
      actions.dismissError = {}
      return actions
    }

    private static var everyDetailAction: AutomationDetailActions {
      var actions = AutomationDetailActions()
      actions.back = {}
      actions.edit = {}
      actions.delete = {}
      actions.runNow = {}
      actions.setPaused = { _ in }
      actions.openSession = { _ in }
      actions.retry = {}
      actions.dismissError = {}
      return actions
    }

    private static var hostileList: AutomationsViewState {
      var state = AutomationsViewState(
        rows: (0..<HostileData.rowCount).map { index in
          var row = AutomationRow(
            id: "\(index)", name: HostileData.text(index),
            scheduleText: HostileData.text(index + 1),
            nextRunText: index.isMultiple(of: 2) ? HostileData.text(index + 2) : nil,
            isPaused: index.isMultiple(of: 3))
          row.isBusy = index.isMultiple(of: 5)
          row.lastRunSessionID = HostileData.text(index)
          return row
        }, hasAny: true, actionError: HostileData.bidirectional)
      state.triggers = HostileData.samples.enumerated().map { index, text in
        AutomationTriggerChip(id: "\(index)", title: text, systemImage: text)
      }
      return state
    }

    private static func detail(name: String, text: String) -> AutomationDetailState {
      AutomationDetailState(
        id: "t1", name: name, isPaused: false, scheduleText: text, prompt: text, agent: text,
        host: text)
    }

    private static var realisticDetail: AutomationDetailState {
      var state = detail(name: "Follow-up monitor", text: "Weekdays at 9:00 AM")
      let indicators: [AutomationRunRow.Indicator] = [
        .failed, .skipped, .inFlight, .unread, .completed, .queued,
      ]
      state.runs = indicators.enumerated().map { index, indicator in
        var run = AutomationRunRow(
          id: "\(index)", indicator: indicator, timestamp: "Today, 8:0\(index) AM")
        run.duration = "1m 4\(index)s"
        if indicator == .failed {
          run.failureStage = "Host"
          run.failureReason = "The host was offline."
        }
        run.sessionID = index.isMultiple(of: 2) ? "s\(index)" : nil
        return run
      }
      return state
    }

    private static var hostileDetail: AutomationDetailState {
      var state = detail(name: HostileData.bidirectional, text: HostileData.bidirectional)
      state.prompt = HostileData.controlCharacters
      state.actionError = HostileData.bidirectional
      state.isBusy = true
      state.runs = (0..<HostileData.rowCount).map { index in
        var run = AutomationRunRow(
          id: "\(index)", indicator: .failed, timestamp: HostileData.text(index))
        run.duration = HostileData.text(index + 1)
        run.statusLabel = HostileData.text(index + 2)
        run.failureStage = HostileData.text(index + 3)
        run.failureReason = HostileData.text(index)
        run.sessionID = index.isMultiple(of: 2) ? "\(index)" : nil
        return run
      }
      return state
    }

    private static func context(
      describe: String = "Every day at 9:00 AM", editing: Bool = false
    ) -> AutomationEditorContext {
      var context = AutomationEditorContext(
        agents: [
          AutomationOption(id: "a1", name: "Claude Code"),
          AutomationOption(id: "a2", name: "Codex"),
        ],
        supportsSessionModes: true, describe: { _ in describe }, isEditing: editing)
      context.hosts = [AutomationOption(id: "h1", name: "ahir-mbp")]
      context.sandboxLabel = "New Sandbox"
      context.supportsProjects = true
      context.projects = [AutomationOption(id: "p1", name: "Docs")]
      context.anchoredScheduling = true
      return context
    }

    /// Long enough to hold every section, with a row for each kind of picker option.
    private static var hostileContext: AutomationEditorContext {
      var context = context(describe: HostileData.unbroken, editing: true)
      let options = (0..<HostileData.rowCount).map {
        AutomationOption(id: "\($0)", name: HostileData.text($0))
      }
      context.agents = options
      context.hosts = options
      context.projects = options
      context.sandboxLabel = HostileData.unbroken
      context.overrides = AutomationOverrideOptions(
        models: options, efforts: options, permissionModes: options)
      context.error = HostileData.unbroken
      context.blocker = HostileData.bidirectional
      context.scheduleProblem = HostileData.controlCharacters
      context.agentNote = HostileData.unbroken
      context.hasContinuingSession = true
      return context
    }

    private static var hostileDraft: AutomationDraftState {
      var draft = AutomationDraftState(
        name: HostileData.unbroken, prompt: HostileData.bidirectional, agentID: "missing-agent",
        schedule: outOfRangeSchedule, continuesSession: true)
      draft.hostID = "missing-host"
      draft.workspace = HostileData.unbroken
      draft.projectID = "missing-project"
      draft.model = "missing-model"
      draft.effort = HostileData.unbroken
      draft.permissionMode = HostileData.controlCharacters
      return draft
    }

    /// Nothing the form offers: every field out of its range, an ending before the epoch.
    private static var outOfRangeSchedule: ScheduleChoice {
      ScheduleChoice(
        preset: .custom, hour: 99, minute: -5, weekdays: [], frequency: .weekly, interval: -7,
        monthDays: [], month: 99, end: .until(.distantPast))
    }

    private static var triggerTemplate: AutomationTriggerTemplate {
      AutomationTriggerTemplate(
        events: [AutomationOption(id: "created", name: "A ticket is created")],
        scopeLabel: "in project", scopePlaceholder: "ENG",
        fields: [
          AutomationTriggerTemplate.Field(
            id: "assignee", title: "Assignee",
            operations: [
              AutomationTriggerTemplate.Operation(
                id: "unassigned", title: "is unassigned", isValueless: true),
              AutomationTriggerTemplate.Operation(id: "is", title: "is", isValueless: false),
            ], placeholder: "name")
        ], instructionsPlaceholder: "What each session does", linkBackLabel: "Post a link back",
        maxInstructions: 10)
    }

    private static func triggerDraft(event: String, condition: String) -> AutomationDraftState {
      var draft = AutomationDraftState(name: "Triage", agentID: "a1")
      var trigger = AutomationTriggerDraft(source: "jira", event: event)
      trigger.scope = HostileData.unbroken
      trigger.instructions = HostileData.unbroken
      trigger.conditions = [
        AutomationTriggerCondition(field: "assignee", operation: "is"),
        AutomationTriggerCondition(field: condition, operation: condition),
      ]
      draft.trigger = trigger
      return draft
    }
  }

  @Suite("Automation state rules")
  struct AutomationStateRulesTests {
    @Test("a draft needs a name, a prompt or trigger, and an agent")
    func canSave() {
      var draft = AutomationDraftState(name: "Brief", prompt: "Summarize", agentID: "a1")
      #expect(draft.canSave)
      draft.name = " \n\t"
      #expect(!draft.canSave, "a blank name doesn't count")
      draft.name = "Brief"
      draft.prompt = "\n  "
      #expect(!draft.canSave, "a blank prompt doesn't count")
      draft.trigger = AutomationTriggerDraft(source: "jira", event: "created")
      #expect(draft.canSave, "a trigger writes the prompt")
      draft.agentID = ""
      #expect(!draft.canSave)
    }

    @Test("a hostile name is still a name")
    func hostileNames() {
      for name in [HostileData.unbroken, HostileData.bidirectional] {
        #expect(AutomationDraftState(name: name, prompt: "Go", agentID: "a1").canSave)
      }
    }

    @Test("suggestions have stable, unique ids and default to the web's schedule")
    func suggestions() {
      let ids = AutomationSuggestion.all.map(\.id)
      #expect(Set(ids).count == ids.count)
      #expect(AutomationSuggestion.all.allSatisfy { !$0.prompt.isEmpty && !$0.title.isEmpty })
      #expect(ScheduleChoice().preset == .daily)
      #expect(ScheduleChoice().end == .never)
    }
  }
#endif
