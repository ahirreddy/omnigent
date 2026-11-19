import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

private let previewPath = "/v1/sandbox-providers/modal/harnesses/claude-native/model-options"

/// An automation on a new sandbox lists that sandbox's models, as the web's
/// `useScheduledHarnessSettings` does.
@MainActor
@Suite("Automation models on a new sandbox", .serialized, .timeLimit(.minutes(1)))
struct AutomationSandboxModelsTests {
  private func pages(provider capabilities: String, preview: String? = nil) async throws
    -> (PagesStore, AppServer)
  {
    let server = newSessionServer()
    if let preview { server.route(previewPath, .json(preview)) }
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"automations_enabled":true,"managed_sandboxes_enabled":true,"sandbox_provider":"modal","sandbox_provider_capabilities":{"modal":\#(capabilities)}}"#
      ))
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    await pages.loadAutomationCatalog()
    return (pages, server)
  }

  private func sandboxDraft() -> AutomationDraftState {
    var draft = AutomationDraftState()
    draft.agentID = "ag_claude"
    draft.runsInSandbox = true
    return draft
  }

  private func context(_ pages: PagesStore, _ draft: AutomationDraftState)
    -> AutomationEditorContext
  {
    AutomationEditorMapping.context(
      pages: pages, inputs: AutomationEditorMapping.Inputs(draft: draft, sessionLink: ""))
  }

  @Test("A gateway catalog lists its models for the agent, with each model's own efforts")
  func gatewayCatalog() async throws {
    let (pages, server) = try await pages(
      provider: #"{"default_models":true}"#,
      preview:
        #"{"configured":false,"status":"ready","models":[{"id":"gw-fast","model":"gw-fast","displayName":"Gateway Fast","supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"high"}]}]}"#
    )
    var draft = sandboxDraft()
    let source = try #require(AutomationModelSource.of(draft, pages: pages))
    await source.load(pages)
    let read = try #require(server.requests("GET", previewPath).first)
    #expect(URLComponents(string: read.url)?.queryItems?.first?.value == "ag_claude")
    draft.model = "gw-fast"
    let shown = context(pages, draft)
    #expect(shown.overrides?.models.map(\.name) == ["Gateway Fast"])
    #expect(shown.overrides?.efforts.map(\.id) == ["low", "high"], "not Claude Code's ladder")
    #expect(shown.blocker == nil)
    #expect(AutomationEditorMapping.sendsOverrides(pages: pages, draft: draft))
  }

  @Test("A harness no sandbox model serves blocks Save and says why")
  func unsupported() async throws {
    let (pages, _) = try await pages(
      provider: #"{"default_models":true}"#,
      preview:
        #"{"configured":false,"status":"unsupported","error":"No gateway route serves Claude.","models":[]}"#
    )
    let draft = sandboxDraft()
    await AutomationModelSource.of(draft, pages: pages)?.load(pages)
    let shown = context(pages, draft)
    #expect(shown.blocker == "No gateway route serves Claude.")
    #expect(shown.overrides?.catalogMessage == nil, "the blocker says it once")
  }

  @Test("A sandbox that can't list models says so; one without a catalog keeps Claude's aliases")
  func unavailableOrNoCatalog() async throws {
    let (failing, _) = try await pages(
      provider: #"{"inference_models":true}"#,
      preview:
        #"{"configured":true,"status":"unavailable","error":"Gateway down","models":[]}"#)
    let draft = sandboxDraft()
    await AutomationModelSource.of(draft, pages: failing)?.load(failing)
    let options = context(failing, draft).overrides
    #expect(options?.models.isEmpty == true, "no aliases stand in for the sandbox's catalog")
    #expect(
      options?.catalogMessage
        == "Could not load models. Default uses the agent\u{2019}s configuration.")

    let (plain, server) = try await pages(provider: #"{"multi_repo":true}"#)
    #expect(AutomationModelSource.of(draft, pages: plain) == nil)
    #expect(server.requests("GET", previewPath).isEmpty)
    #expect(
      context(plain, draft).overrides?.models.map(\.id)
        == AutomationEditorMapping.claudeModels.map(\.id))
  }
}
