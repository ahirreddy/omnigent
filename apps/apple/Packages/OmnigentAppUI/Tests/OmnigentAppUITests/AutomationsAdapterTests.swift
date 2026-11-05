import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
@Suite("Automations mapping")
struct AutomationsAdapterTests {
  private func automation(rrule: String) -> Automation {
    Automation(
      id: "t1", name: "Standup", prompt: "Summarize", rrule: rrule,
      scheduleText: describeSchedule(rrule: rrule), agentId: "a1", timezone: "Europe/Paris",
      continuesSession: true, state: .active, nextRunAt: nil, lastRunAt: nil,
      lastRunStatus: nil, lastRunSessionId: nil, updatedAt: 0)
  }

  private var catalog: OmnigentCoreFFI.CreationCatalog {
    OmnigentCoreFFI.CreationCatalog(
      hosts: [
        CreationHost(
          hostId: "h-off", name: "Old", status: "offline", sandboxProvider: nil,
          configuredHarnesses: nil),
        CreationHost(
          hostId: "h1", name: "Laptop", status: "online", sandboxProvider: nil,
          configuredHarnesses: nil),
      ],
      agents: [
        OmnigentCoreFFI.CreationAgent(
          id: "claude", name: "Claude Code", harness: "claude-native", description: nil,
          harnessId: "claude-native", supportsCreation: true, pickerSection: .harness),
        OmnigentCoreFFI.CreationAgent(
          id: "polly", name: "Polly", harness: "omnigent", description: nil,
          harnessId: "omnigent", supportsCreation: true, pickerSection: .agent),
      ])
  }

  @Test("An editable rule round-trips through the editor; the saved zone is kept")
  func editableRule() {
    let rule = "FREQ=WEEKLY;BYDAY=MO,FR;BYHOUR=8;BYMINUTE=30"
    let saved = automation(rrule: rule)
    let draft = AutomationsMapping.draft(saved)
    #expect(draft.schedule?.preset == .weekly)
    #expect(draft.schedule?.weekdays == [0, 4])
    #expect(draft.keptRule == nil)
    #expect(draft.continuesSession)
    #expect(
      AutomationsMapping.describe(draft.schedule ?? ScheduleChoice())
        == "Weekly on Monday and Friday at 8:30 AM")
    let request = AutomationsMapping.request(
      draft, prompt: draft.prompt, saved: saved, sessionModes: false, sendsOverrides: false)
    #expect(request.rrule == rule)
    #expect(request.timezone == "Europe/Paris")
    #expect(request.continuesSession == nil)
  }

  @Test("End conditions round-trip; a rule the editor cannot show is kept as it is")
  func endsAndKeptRules() throws {
    let counted = AutomationsMapping.draft(
      automation(rrule: "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;COUNT=5"))
    #expect(counted.schedule?.end == .count(5))
    let until = AutomationsMapping.draft(
      automation(rrule: "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;UNTIL=20261231T235959Z"))
    let date = Date(timeIntervalSince1970: 1_798_761_599)
    #expect(until.schedule?.end == .until(date))
    #expect(
      buildScheduleRrule(model: AutomationsMapping.model(try #require(until.schedule)))
        == "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;UNTIL=20261231T235959Z")

    let rule = "FREQ=DAILY;BYHOUR=8;BYMINUTE=0;BYSETPOS=1"
    let kept = AutomationsMapping.draft(automation(rrule: rule))
    #expect(kept.schedule == nil)
    let request = AutomationsMapping.request(
      kept, prompt: kept.prompt, saved: automation(rrule: rule), sessionModes: true,
      sendsOverrides: false)
    #expect(request.rrule == rule)
    #expect(request.continuesSession == true)
  }

  @Test("Custom schedules and run counts need automations_v2; a saved past end may stay")
  func scheduleProblems() {
    let now = Date(timeIntervalSince1970: 1_793_865_600)
    let counted = ScheduleChoice(end: .count(3))
    #expect(
      AutomationsMapping.scheduleProblem(counted, saved: nil, anchored: false, now: now)?
        .contains("does not support") == true)
    #expect(
      AutomationsMapping.scheduleProblem(counted, saved: nil, anchored: true, now: now) == nil)
    let past = ScheduleChoice(end: .until(now.addingTimeInterval(-60)))
    #expect(
      AutomationsMapping.scheduleProblem(past, saved: nil, anchored: true, now: now)
        == "Choose an end date in the future.")
    let rule = buildScheduleRrule(model: AutomationsMapping.model(past))
    #expect(
      AutomationsMapping.scheduleProblem(
        past, saved: automation(rrule: rule), anchored: true, now: now) == nil)
  }

  @Test("A new automation starts on the first creatable agent and the first online host")
  func newDraft() throws {
    let suggestion = try #require(AutomationSuggestion.all.first)
    let draft = AutomationsMapping.newDraft(suggestion, catalog: catalog)
    #expect(draft.name == suggestion.title)
    #expect(draft.agentID == "claude")
    #expect(draft.hostID == "h1")
    #expect(AutomationsMapping.newDraft(nil, catalog: nil).agentID.isEmpty)
    #expect(AutomationEditorMapping.blocker(AutomationDraftState(), isEditing: false) != nil)
    var pinned = AutomationDraftState()
    pinned.workspace = "/src"
    #expect(
      AutomationEditorMapping.blocker(pinned, isEditing: true)
        == "Pick a host before pinning a workspace.")
    pinned.runsInSandbox = true
    #expect(AutomationEditorMapping.blocker(pinned, isEditing: false) == nil)
  }

  @Test("Only Claude Code takes the model, effort and permission overrides")
  func overrides() {
    #expect(AutomationEditorMapping.sendsOverrides(catalog, agentID: "claude"))
    #expect(!AutomationEditorMapping.sendsOverrides(catalog, agentID: "polly"))
    var draft = AutomationsMapping.newDraft(nil, catalog: catalog)
    draft.model = "opus"
    draft.workspace = "  "
    let request = AutomationsMapping.request(
      draft, prompt: "Go", saved: nil, sessionModes: true, sendsOverrides: true)
    #expect(request.sendsOverrides)
    #expect(request.modelOverride == "opus")
    #expect(request.reasoningEffort == nil)
    #expect(request.hostId == "h1")
    #expect(request.workspace == nil)
  }

  @Test("A trigger opens hourly in one session and renders its prompt once complete")
  func trigger() throws {
    #expect(AutomationTriggerMapping.chips.map(\.id) == ["jira", "slack", "github"])
    let source = try #require(AutomationTriggerMapping.source("jira"))
    var draft = AutomationTriggerMapping.newDraft(source, base: AutomationDraftState())
    #expect(draft.name == "Jira tickets")
    #expect(draft.continuesSession)
    #expect(draft.schedule?.preset == .hourly)
    let link = "https://omni.example.com/c/CONVERSATION_ID"
    #expect(
      AutomationTriggerMapping.prompt(draft, sessionLink: link, sendsOverrides: false).isEmpty)
    draft.trigger?.scope = "ES"
    draft.trigger?.instructions = "Investigate the ticket."
    draft.trigger?.conditions = [AutomationTriggerCondition(field: "label", operation: "is")]
    #expect(
      AutomationTriggerMapping.prompt(draft, sessionLink: link, sendsOverrides: false).isEmpty)
    draft.trigger?.conditions[0].value = "omnigent"
    let prompt = AutomationTriggerMapping.prompt(draft, sessionLink: link, sendsOverrides: false)
    #expect(prompt.contains(#"project = "ES" AND labels = "omnigent""#))
    #expect(prompt.contains(link))
    let template = AutomationTriggerMapping.template(source)
    #expect(template.fields.first { $0.id == "assignee" }?.operations.last?.title == "is assigned")
  }

  @Test("Runs read like the web's history; hosts are named")
  func runRows() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let now = Date(timeIntervalSince1970: 1_793_865_600)
    let run = AutomationRun(
      id: "r1", status: .succeeded, inFlightLabel: nil, startedAt: 1_793_865_600 - 86_400,
      duration: "3s", sessionId: "c1", failureStage: nil, failureReason: nil, unread: true)
    let row = AutomationDetailMapping.row(run, now: now, calendar: calendar)
    #expect(row.indicator == .unread)
    #expect(row.timestamp.hasPrefix("Yesterday, "))
    #expect(row.sessionID == "c1")
    var saved = automation(rrule: "FREQ=HOURLY;BYMINUTE=0")
    #expect(AutomationDetailMapping.host(saved, catalog: catalog) == "Most recently active host")
    saved.hostId = "h1"
    #expect(AutomationDetailMapping.host(saved, catalog: catalog) == "Laptop")
    saved.runsInSandbox = true
    #expect(AutomationDetailMapping.host(saved, catalog: catalog) == "New Sandbox")
  }
}
