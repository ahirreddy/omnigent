import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

private let workflowID = "0123456789abcdef0123456789abcdef"

/// New automation's Workflow field, as the web's: a run follows a saved workflow as saved, or
/// with additional instructions an automation already kept, each in a session of its own.
@MainActor
@Suite("Automations: the Workflow field", .serialized, .timeLimit(.minutes(1)))
struct AutomationWorkflowFieldTests {
  private let triage = SavedWorkflow(
    id: workflowID, name: "Triage", description: "", isDraft: false, sharedWithMe: false,
    ownerDisplayName: nil, shareable: true, createdAt: 0, updatedAt: 0)

  private func automation(prompt: String) -> Automation {
    Automation(
      id: "t1", name: "Nightly", prompt: prompt, rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0",
      scheduleText: "", agentId: "ag_claude", timezone: "UTC", continuesSession: false,
      state: .active, nextRunAt: nil, lastRunAt: nil, lastRunStatus: nil,
      lastRunSessionId: nil, updatedAt: 0)
  }

  @Test("Made from a workflow, it runs the workflow as saved in new sessions")
  func lockedWorkflow() {
    let draft = AutomationsMapping.workflowDraft(triage, catalog: nil)
    #expect(draft.workflow?.id == workflowID && draft.workflowLocked)
    #expect(!draft.showsInstructions && draft.canSave == false, "it still needs an agent")
    #expect(AutomationsMapping.runsSavedWorkflow(draft))
    let prompt = AutomationsMapping.prompt(draft, triggerPrompt: "", skillPrefix: "/")
    #expect(prompt == "/workflow Run the saved workflow \"Triage\" (ID \(workflowID)).")
    var continuing = draft
    continuing.continuesSession = true
    #expect(!AutomationEditorMapping.withWorkflowSessions(continuing).continuesSession)
  }

  @Test("A saved run of a workflow reopens on it, keeping its additional instructions")
  func reopensOnItsWorkflow() {
    let message = savedWorkflowMessage(
      skillPrefix: "/", workflowId: workflowID, workflowName: "Triage", details: "Only P1s.",
      reviewPlanFirst: false)
    let draft = AutomationsMapping.draft(automation(prompt: message), workflows: true)
    #expect(draft.workflow?.name == "Triage" && !draft.workflowLocked)
    #expect(draft.showsInstructions && draft.prompt == "Only P1s.")
    #expect(AutomationsMapping.prompt(draft, triggerPrompt: "", skillPrefix: "/") == message)
    // Another workflow chosen leaves the typed text out of its runs.
    var switched = draft
    switched.workflow = AutomationOption(id: String(repeating: "f", count: 32), name: "Other")
    #expect(!switched.showsInstructions)
    #expect(
      !AutomationsMapping.prompt(switched, triggerPrompt: "", skillPrefix: "/").contains(
        "Only P1s."))
    // Where the server runs no workflows, the message stays the instructions.
    let plain = AutomationsMapping.draft(automation(prompt: message), workflows: false)
    #expect(plain.workflow == nil && plain.prompt == message)
  }

  @Test("The field lists the caller's workflows where the server runs them")
  func offered() async throws {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"automations_enabled":true,"workflows":true,"features":{"workflows":true}}"#
      ))
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    var draft = AutomationDraftState(name: "Nightly", agentID: "ag_claude")
    var inputs = AutomationEditorMapping.Inputs(draft: draft, sessionLink: "")
    inputs.workflows = [triage]
    var context = AutomationEditorMapping.context(pages: pages, inputs: inputs)
    #expect(context.offersWorkflows && context.workflows.map(\.name) == ["Triage"])
    #expect(!context.workflowNeedsNewSessions)
    draft.workflow = AutomationOption(id: workflowID, name: "Triage")
    inputs.draft = draft
    context = AutomationEditorMapping.context(pages: pages, inputs: inputs)
    #expect(context.workflowNeedsNewSessions)
    #expect(draft.canSave, "a workflow needs no instructions")
  }

  @Test("A trigger with a workflow runs it for each match and reopens on it")
  func triggerWorkflow() async throws {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"automations_enabled":true,"workflows":true,"scheduled_task_trigger_headers":true,"features":{"workflows":true}}"#
      ))
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    let source = try #require(AutomationTriggerMapping.source("jira"))
    var draft = AutomationTriggerMapping.newDraft(
      source, base: AutomationDraftState(agentID: "ag_claude"),
      schedule: ScheduleChoice(preset: .interval, frequency: .minutely, interval: 10))
    draft.trigger?.scope = "ES"
    #expect(
      AutomationEditorMapping.triggerPrompt(
        pages: pages, draft: draft, saved: nil, sessionLink: ""
      ).isEmpty, "without a workflow the instructions are required")
    draft.workflow = AutomationOption(id: workflowID, name: "Triage")
    #expect(!draft.showsInstructions)
    let saved = AutomationEditorMapping.triggerPrompt(
      pages: pages, draft: draft, saved: nil, sessionLink: "")
    #expect(saved.contains("Run the saved workflow") && saved.contains("(ID \(workflowID))"))
    var trigger = automation(prompt: saved)
    trigger.isTrigger = true
    let reopened = AutomationsMapping.draft(trigger, workflows: true)
    #expect(reopened.workflow?.id == workflowID)
    #expect(reopened.trigger?.instructions.isEmpty == true)
    #expect(!reopened.showsInstructions)
    #expect(reopened.trigger?.scope == "ES")
  }
}
