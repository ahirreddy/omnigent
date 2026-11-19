import SwiftUI
import Testing

@testable import OmnigentUIComponents

/// The editor's structure, as the web's dialog orders it, on every platform: no drawing, so it
/// runs on iOS too.
@Suite("Automation editor structure")
@MainActor
struct AutomationEditorStructureTests {
  private func sheet(
    _ draft: AutomationDraftState, context: AutomationEditorContext
  ) -> AutomationEditorSheet {
    AutomationEditorSheet(draft: .constant(draft), context: context, save: {}, cancel: {})
  }

  private func context(editing: Bool = false) -> AutomationEditorContext {
    var context = AutomationEditorContext(
      agents: [AutomationOption(id: "a1", name: "Claude Code")], supportsSessionModes: true,
      describe: { _ in "Every day at 9:00 AM" }, isEditing: editing)
    context.supportsProjects = true
    context.overrides = AutomationOverrideOptions(
      models: [AutomationOption(id: "opus", name: "Opus")],
      efforts: [AutomationOption(id: "high", name: "High")], permissionModes: [])
    context.mcpServices = [AutomationMcpOption(id: "github", title: "GitHub", isConnected: true)]
    return context
  }

  @Test("Advanced settings hold the web's rows, in its order")
  func advancedOrder() {
    var draft = AutomationDraftState(agentID: "a1")
    draft.hostID = "h1"
    let rows = sheet(draft, context: context()).advancedRows()
    #expect(
      rows.map(\.id) == [
        "model", "effort", "session", "mcp", "ends", "workspace", "project", "cost",
      ])
    #expect(rows.map(\.label).last == "Cost limit per run (USD)")
  }

  @Test("a new automation picks its type and schedule first; an edit keeps them under Advanced")
  func typeRowAndSchedule() {
    let new = sheet(AutomationDraftState(), context: context())
    #expect(new.showsTypeRow)
    #expect(!new.scheduleInAdvanced)
    #expect(new.saveTitle == "Create")
    let edited = sheet(AutomationDraftState(), context: context(editing: true))
    #expect(!edited.showsTypeRow)
    #expect(edited.scheduleInAdvanced)
    #expect(edited.saveTitle == "Save changes")
    #expect(edited.advancedRows().map(\.id).contains("schedule"))
    #expect(!new.advancedRows().map(\.id).contains("schedule"))
    var copy = AutomationDraftState()
    copy.sourceSessionID = "s1"
    copy.sourceSessionTitle = "Release notes"
    let fromSession = sheet(copy, context: context())
    #expect(!fromSession.showsTypeRow, "a session copy keeps its schedule type")
    #expect(fromSession.title == "New automation from \u{201C}Release notes\u{201D}")
    #expect(!fromSession.advancedRows().map(\.id).contains("session"), "each run starts anew")
  }

  @Test("a trigger has no schedule or session mode, and a new one picks its task session")
  func triggerRows() {
    var draft = AutomationDraftState(agentID: "a1", continuesSession: true)
    draft.trigger = AutomationTriggerDraft(source: "jira", event: "created")
    let ids = sheet(draft, context: context()).advancedRows().map(\.id)
    #expect(!ids.contains("session"))
    #expect(!ids.contains("ends"))
    #expect(ids.contains("task-session"))
  }

  @Test("a problem whose fix is under Advanced settings opens them, as the web's")
  func advancedNeedsAttention() {
    var context = context()
    #expect(!sheet(AutomationDraftState(), context: context).advancedNeedsAttention)
    context.costLimitProblem = "Enter a cost limit greater than zero, or leave it blank."
    #expect(sheet(AutomationDraftState(), context: context).advancedNeedsAttention)
    context.costLimitProblem = nil
    context.mcpProblem = "Loading MCP services\u{2026}"
    #expect(!sheet(AutomationDraftState(), context: context).advancedNeedsAttention)
    var pinned = AutomationDraftState()
    pinned.workspace = "/work"
    #expect(sheet(pinned, context: self.context()).advancedNeedsAttention)
  }

  @Test("the schedule button names the schedule, a kept rule, or that it needs attention")
  func scheduleSummary() {
    #expect(
      sheet(AutomationDraftState(), context: context()).scheduleSummary == "Every day at 9:00 AM")
    let kept = AutomationDraftState(schedule: nil, keptRule: "Every 3rd Tuesday")
    #expect(sheet(kept, context: context(editing: true)).scheduleSummary == "Every 3rd Tuesday")
    var problem = context()
    problem.scheduleProblem = "Choose a day."
    #expect(sheet(AutomationDraftState(), context: problem).scheduleSummary == "Needs attention")
  }

  @Test(
    "a trigger's card shows the description's first sentence; the rest waits for the info button")
  func triggerCopy() {
    var template = AutomationTriggerTemplate(
      events: [AutomationOption(id: "created", name: "Ticket created")], scopeLabel: "project",
      scopePlaceholder: "ENG", fields: [], instructionsPlaceholder: "", linkBackLabel: "",
      maxInstructions: 10)
    template.serviceName = "Jira"
    template.eventDetails = [
      "created": .init(
        description: "Starts a session for each new ticket. Checks look back to the last one.",
        scopeLabel: "project", scopePlaceholder: "ENG",
        authorAction: "create a ticket in these projects")
    ]
    var trigger = AutomationTriggerDraft(source: "jira", event: "created")
    let copy = AutomationTriggerCopy(template: template, trigger: trigger)
    #expect(copy.summary == "Starts a session for each new ticket.")
    #expect(copy.details.hasPrefix("Checks look back to the last one."))
    #expect(copy.details.contains("Up to 10 matches per run"))
    #expect(copy.sourceWarning.hasPrefix("Anyone who can create a ticket in these projects"))
    #expect(copy.sourceWarning.hasSuffix("Links are posted with your Jira account."))
    trigger.instructions = "01234567890"
    #expect(AutomationTriggerCopy(template: template, trigger: trigger).instructionsTooLong)
  }
}
