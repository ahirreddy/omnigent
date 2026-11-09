import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The states a page passes through that its usual flows leave too fast to see.
@MainActor
@Suite("Page edge states", .serialized, .timeLimit(.minutes(1)))
struct PageEdgeStatesTests {
  @Test("A project asked for from the sidebar is applied once the form opens")
  func pendingProject() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/projects/p1", .json(#"{"id":"p1","name":"Alpha","default_host_id":"box"}"#))
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    creation.pendingProject = ProjectSummary(id: "p1", name: "Alpha", icon: nil)
    let form = try isolatedForm()
    let screen = OffscreenWindow(
      NewSessionContainer(connection: connection, form: form) { _ in }, width: 900, height: 700)
    defer { screen.close() }
    try await settle(screen, until: "the project") { form.project?.name == "Alpha" }
    #expect(creation.pendingProject == nil, "applied only once")
  }

  @Test("A form that turns to a sandbox reads what the sandbox can use")
  func sandboxChoices() async throws {
    let server = newSessionServer()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"managed_sandboxes_enabled":true,"sandbox_providers":["modal"],"default_sandbox_provider":"modal","enabled_connections":["github"]}"#
      ))
    let repositories = "/v1/connections/github/repos"
    server.route(repositories, .json(#"{"connected":true,"truncated":false,"repos":[]}"#))
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    let screen = OffscreenWindow(
      NewSessionContainer(connection: connection, form: form) { _ in }, width: 900, height: 700)
    defer { screen.close() }
    try await settle(screen, until: "the catalog") {
      form.sandboxes != nil && creation.catalog.value != nil
    }
    let before = server.requests("GET", repositories).count
    form.isSandbox = true
    try await settle(screen, until: "the sandbox's choices") {
      server.requests("GET", repositories).count > before
    }
  }

  @Test("An automation watching a source shows that source's template and prompt")
  func editorTrigger() async throws {
    let connection = try await signedInStore(threeSessionServer())
    let pages = try #require(connection.pages)
    let source = try #require(triggerSources().first)
    var draft = AutomationTriggerMapping.newDraft(source, base: AutomationDraftState())
    draft.trigger?.scope = "PROJ"
    draft.trigger?.instructions = "Triage it"
    let context = AutomationEditorMapping.context(
      pages: pages,
      inputs: AutomationEditorMapping.Inputs(draft: draft, sessionLink: "", saveError: nil))
    #expect(context.trigger != nil)
    #expect(context.triggerPrompt.contains("Triage it"))

    var unknown = draft
    unknown.trigger?.source = "no-such-source"
    let plain = AutomationEditorMapping.context(
      pages: pages,
      inputs: AutomationEditorMapping.Inputs(draft: unknown, sessionLink: "", saveError: nil))
    #expect(plain.trigger == nil)
  }
}
