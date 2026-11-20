import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A trigger's matching sessions take their own model, effort and permissions, as the web's
/// worker settings: a new trigger's follow the polling session until changed.
@MainActor
@Suite("Automations: a trigger's matching sessions", .serialized, .timeLimit(.minutes(1)))
struct AutomationTriggerWorkerTests {
  private func newTrigger() throws -> AutomationDraftState {
    let source = try #require(AutomationTriggerMapping.source("jira"))
    var draft = AutomationTriggerMapping.newDraft(
      source, base: AutomationDraftState(agentID: "ag_claude"),
      schedule: ScheduleChoice(preset: .interval, frequency: .minutely, interval: 10))
    draft.hostID = "mac"
    draft.trigger?.scope = "ES"
    draft.trigger?.instructions = "Investigate the ticket."
    return draft
  }

  @Test("A new trigger's follow the polling session, without modes that skip approval")
  func followsPolling() async throws {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"automations_enabled":true,"automation_triggers":true,"session_create_permission_modes":true}"#
      ))
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    await pages.loadAutomationCatalog()
    var draft = try newTrigger()
    func context() -> AutomationEditorContext {
      AutomationEditorMapping.context(
        pages: pages, inputs: AutomationEditorMapping.Inputs(draft: draft, sessionLink: ""))
    }
    let options = try #require(context().workerOptions)
    #expect(
      !options.permissionModes.contains {
        AutomationEditorMapping.approvalSkippingModes.contains($0.id)
      })
    let mode = try #require(options.permissionModes.first?.id)
    draft.permissionMode = mode
    let following = context()
    #expect(following.workerInheritsPolling)
    #expect(following.workerDefaults?.permissionMode == mode)
    #expect(following.workerDefaults?.followsTarget == true)
  }

  @Test("Changed ones go where the automation runs, and a new harness drops them")
  func changed() throws {
    var draft = try newTrigger()
    var worker = AutomationTriggerWorker(
      inSandboxes: false, agentID: nil, model: "sonnet", effort: "", permissionMode: "")
    worker.followsTarget = true
    draft.trigger?.worker = worker
    draft.runsInSandbox = true
    let budget = triggerMessageBudget(
      serverMaxChars: 32_000, target: .host(name: "Laptop", longMessages: true),
      savedMaxChars: nil)
    let config = AutomationTriggerMapping.config(
      draft, budget: budget, workerPermissionMode: "", sendsOverrides: true)
    #expect(config?.worker.placement == .managed)
    #expect(config?.worker.model == "sonnet")
    AutomationsMapping.restoreOverrides(&draft, from: nil)
    #expect(draft.trigger?.worker == nil)
  }
}
