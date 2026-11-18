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
    let draft = AutomationsMapping.newDraft(catalog: catalog)
    #expect(draft.name.isEmpty)
    #expect(draft.agentID == "claude")
    #expect(draft.hostID == "h1")
    // Nobody watches an unattended run, so Claude Code starts in its auto mode.
    #expect(draft.permissionMode == "auto")
    #expect(AutomationsMapping.newDraft(catalog: nil).agentID.isEmpty)
    #expect(AutomationEditorMapping.blocker(AutomationDraftState(), isEditing: false) != nil)
    var pinned = AutomationDraftState()
    pinned.workspace = "/src"
    #expect(
      AutomationEditorMapping.blocker(pinned, isEditing: true)
        == "Pick a host before pinning a workspace.")
    pinned.runsInSandbox = true
    #expect(AutomationEditorMapping.blocker(pinned, isEditing: false) == nil)
  }

  @Test("Every native harness with model settings takes them; the cost limit and services go too")
  func overrides() {
    #expect(AutomationEditorMapping.takesModel(catalog, agentID: "claude"))
    #expect(!AutomationEditorMapping.takesModel(catalog, agentID: "polly"))
    #expect(AutomationEditorMapping.modelHarnesses.contains("codex-native"))
    var draft = AutomationsMapping.newDraft(catalog: catalog)
    draft.model = "opus"
    draft.workspace = "  "
    draft.maxCost = "2.5"
    draft.mcpServices = ["github"]
    let request = AutomationsMapping.request(
      draft, prompt: "Go", saved: nil, sessionModes: true, sendsOverrides: true,
      sendsMcpServices: true)
    #expect(request.sendsOverrides)
    #expect(request.modelOverride == "opus")
    #expect(request.reasoningEffort == nil)
    #expect(request.hostId == "h1")
    #expect(request.workspace == nil)
    #expect(request.maxCostUsd == "2.5")
    #expect(request.mcpServices == ["github"])
    let offline = AutomationsMapping.request(
      draft, prompt: "Go", saved: nil, sessionModes: true, sendsOverrides: true)
    #expect(offline.mcpServices == nil)
  }

  @Test("A trigger opens on the polling interval in one session and renders main's prompt")
  func trigger() throws {
    #expect(
      AutomationTriggerMapping.cards.map(\.id) == [
        "jira", "slack", "github", "linear", "pagerduty",
      ])
    #expect(AutomationTriggerMapping.cards.last?.requirement == "Requires a PagerDuty MCP server.")
    let source = try #require(AutomationTriggerMapping.source("jira"))
    let polling = ScheduleChoice(preset: .interval, frequency: .minutely, interval: 10)
    var draft = AutomationTriggerMapping.newDraft(
      source, base: AutomationDraftState(), schedule: polling)
    #expect(draft.name == "Jira tickets")
    #expect(draft.continuesSession)
    #expect(draft.isTrigger)
    #expect(AutomationsMapping.describe(try #require(draft.schedule)) == "Every 10 minutes")
    let budget = triggerMessageBudget(
      serverMaxChars: 32_000, target: .host(name: "Laptop", longMessages: true),
      savedMaxChars: nil)
    let config = {
      AutomationTriggerMapping.config(
        draft, budget: budget, workerPermissionMode: "", sendsOverrides: false)
    }
    #expect(config() == nil)
    draft.trigger?.scope = "ES"
    draft.trigger?.instructions = "Investigate the ticket."
    draft.trigger?.conditions = [AutomationTriggerCondition(field: "label", operation: "is")]
    #expect(config() == nil)
    draft.trigger?.conditions[0].value = "omnigent"
    let link = "https://omni.example.com/c/CONVERSATION_ID"
    let context = AutomationTriggerMapping.context(draft, sessionLink: link, budget: budget)
    #expect(context.pollingIntervalMinutes == 10)
    let saved = AutomationTriggerMapping.prompt(config(), context: context, withHeader: true)
    #expect(saved.hasPrefix("<!-- omnigent-trigger v1 {\"source\":\"jira\""))
    #expect(saved.contains(#"project = "ES" AND labels = "omnigent""#))
    #expect(saved.contains(link))
    // An older server would send the header to the model, so it gets the prompt alone.
    let bare = AutomationTriggerMapping.prompt(config(), context: context, withHeader: false)
    #expect(bare.hasPrefix("This automation watches Jira"))
    // The header reopens the form with the same fields.
    let reopened = AutomationsMapping.draft(
      Automation(
        id: "t1", name: "Jira tickets", prompt: saved, rrule: "FREQ=MINUTELY;INTERVAL=10",
        scheduleText: "Every 10 minutes", agentId: "a1", timezone: "UTC",
        continuesSession: true, state: .active, nextRunAt: nil, lastRunAt: nil,
        lastRunStatus: nil, lastRunSessionId: nil, updatedAt: 0, isTrigger: true))
    #expect(reopened.trigger?.scope == "ES")
    #expect(reopened.trigger?.conditions.first?.value == "omnigent")
    #expect(reopened.schedule?.preset == .interval)
    #expect(reopened.trigger?.worker?.inSandboxes == false)
    let template = AutomationTriggerMapping.template(source, budget: budget)
    #expect(template.fields.first { $0.id == "assignee" }?.operations.last?.title == "is assigned")
    #expect(template.maxInstructions == 16_000)
    #expect(template.eventDetails["assigned"]?.target?.word == "to")
    #expect(template.fields.contains { $0.namePlaceholder == "ES Component" })
  }

}

extension AutomationsAdapterTests {
  @Test("An older trigger edits its instructions alone and puts them back")
  func legacyTrigger() throws {
    let link = "https://omni.example.com/c/CONVERSATION_ID"
    let fields = TriggerFields(
      event: "created", scope: "ES", scopeOperator: nil, conditions: [], target: nil,
      instructions: "Investigate the ticket.", linkBack: true, linkBackTouched: nil)
    let config = TriggerConfig(
      source: .jira, fields: fields, taskSession: false,
      worker: TriggerWorker(
        placement: .sameHost, agentId: nil, model: "", effort: "", permissionMode: ""))
    let legacy = renderTriggerConfigPrompt(
      config: config,
      context: TriggerConfigContext(
        sessionLink: link, pollingIntervalMinutes: nil, taskSessionTitle: nil,
        messageMaxChars: nil))
    var saved = automation(rrule: "FREQ=HOURLY;BYMINUTE=0")
    saved.prompt = legacy
    saved.isTrigger = true
    var draft = AutomationsMapping.draft(saved)
    #expect(draft.trigger == nil)
    #expect(draft.prompt == "Investigate the ticket.")
    #expect(draft.systemPrompt != nil)
    #expect(AutomationsMapping.prompt(draft, triggerPrompt: "") == legacy)
    draft.prompt = "Fix it."
    #expect(
      AutomationsMapping.prompt(draft, triggerPrompt: "").contains(
        "Instructions for each session:\nFix it.\n"))
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
    // A failed run says what it cost, what it waits on and the server's detail; a succeeded
    // one whose session still works shows a spinner.
    var failed = run
    failed.status = .failed
    failed.failureReason = "Couldn't create the sandbox."
    failed.errorDetail = "Quota exceeded."
    failed.sessionCost = "Session cost $1.23"
    failed.needsApproval = true
    let prs = RunPullRequests(
      runId: "r1",
      pullRequests: [
        RunPullRequest(
          url: "https://git.example.com/acme/app/pull/7", repository: "acme/app", number: "#7",
          title: nil, status: .merged, statusLabel: "Merged", createdByRun: true)
      ], summary: "PR #7 merged")
    let failedRow = AutomationDetailMapping.row(
      failed, now: now, calendar: calendar, pullRequests: prs)
    #expect(failedRow.indicator == .failed)
    #expect(failedRow.errorDetail == "Quota exceeded.")
    #expect(failedRow.sessionCost == "Session cost $1.23")
    #expect(failedRow.needsApproval)
    #expect(failedRow.pullRequestSummary == "PR #7 merged")
    #expect(failedRow.pullRequests.first?.title == "acme/app")
    #expect(failedRow.pullRequests.first?.origin == "Opened by this run")
    var working = run
    working.sessionRunning = true
    let workingRow = AutomationDetailMapping.row(working, now: now, calendar: calendar)
    #expect(workingRow.indicator == .sessionRunning)
    #expect(workingRow.statusLabel == "Session running")
    var saved = automation(rrule: "FREQ=HOURLY;BYMINUTE=0")
    #expect(AutomationDetailMapping.host(saved, catalog: catalog) == "Most recently active host")
    saved.hostId = "h1"
    #expect(AutomationDetailMapping.host(saved, catalog: catalog) == "Laptop")
    saved.runsInSandbox = true
    #expect(AutomationDetailMapping.host(saved, catalog: catalog) == "New Sandbox")
  }
}
