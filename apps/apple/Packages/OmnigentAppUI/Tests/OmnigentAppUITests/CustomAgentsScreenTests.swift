import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// A server with one shared agent and one of the caller's.
private func agentsServer() -> AppServer {
  let server = AppServer()
  server.route(
    "/v1/agents",
    .json(
      #"{"data":[{"id":"a1","name":"Reviewer","description":"Reviews","harness":"claude-native"}],"has_more":false}"#
    ))
  server.route(
    "/v1/agents/a1/config",
    .json(
      #"{"id":"a1","name":"Reviewer","version":2,"model":"m","harness":"claude-native","instructions":"Be kind"}"#
    ))
  return server
}

/// Settings > Custom agents.
@MainActor
@Suite("Custom agents settings", .serialized, .timeLimit(.minutes(1)))
struct CustomAgentsScreenTests {
  private func opened(
    _ server: AppServer = agentsServer(), canEdit: Bool = true
  ) async throws -> OffscreenWindow<CustomAgentsSettingsView> {
    let connection = try await signedInStore(server)
    let screen = OffscreenWindow(
      CustomAgentsSettingsView(connection: connection, canEdit: canEdit), width: 700, height: 600)
    try await settle(screen, untilShowing: "Reviewer")
    return screen
  }

  /// The text field showing `placeholder`.
  private func field<Content: View>(
    _ placeholder: String, in screen: OffscreenWindow<Content>
  ) throws -> NSTextField {
    let fields = screen.allViews.compactMap { $0 as? NSTextField }
    return try #require(fields.first { $0.placeholderString == placeholder })
  }

  /// Types what Save needs: the agent's name and a model.
  private func fillIn<Content: View>(_ name: String, in screen: OffscreenWindow<Content>) throws {
    try screen.click(field("my-agent", in: screen))
    try screen.type(name)
    try screen.click(field("claude-sonnet-4-5", in: screen))
    try screen.type("model-1")
    screen.settle(0.05)
  }

  // The list's controls, top to bottom: Create, then Edit on your agent.
  private static let create = 0
  private static let edit = 1

  @Test("Create saves the agent, reloads and opens it")
  func creating() async throws {
    let server = agentsServer()
    server.route("/v1/agents", method: "POST", .json(#"{"id":"a1","name":"Reviewer"}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.create)
    try await settle(screen, untilShowing: "Create Custom Agent")
    try fillIn("helper", in: screen)
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "the create") {
      !server.requests("POST", "/v1/agents").isEmpty
    }
    try await settle(screen, untilShowing: "Delete Agent…")
    #expect(!server.requests("GET", "/v1/agents/a1/config").isEmpty, "the editor opens it")
  }

  @Test("Cancel leaves without saving")
  func cancelCreate() async throws {
    let server = agentsServer()
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.create)
    try await settle(screen, untilShowing: "Create Custom Agent")
    try pressShortcut(screen, keyCode: 53, characters: "\u{1b}", modifiers: [])
    try await pause(screen, .milliseconds(300))
    #expect(try !screen.shows("Create Custom Agent"))
    #expect(server.requests("POST", "/v1/agents").isEmpty)
  }

  @Test("Edit reads the agent; Save sends the change and Back closes it")
  func editing() async throws {
    let server = agentsServer()
    server.route(
      "/v1/agents/a1", method: "PATCH",
      .json(#"{"id":"a1","name":"Reviewer","version":3,"model":"m","harness":"claude-native"}"#))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.edit)
    try await settle(screen, untilShowing: "Delete Agent…")
    let description = try #require(
      screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    try screen.click(description)
    try screen.type("better")
    try await pause(screen)
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "the save") {
      !server.requests("PATCH", "/v1/agents/a1").isEmpty
    }
    #expect(try server.patched("/v1/agents/a1").first?["description"] as? String == "better")
    try screen.clickControl(at: 0)
    try await settle(screen, untilShowing: "Yours")
  }

  @Test("Back leaves the editor")
  func backOnly() async throws {
    let screen = try await opened()
    defer { screen.close() }
    try screen.clickControl(at: Self.edit)
    try await settle(screen, untilShowing: "Delete Agent…")
    try screen.clickControl(at: 0)
    try await settle(screen, untilShowing: "Yours")
  }

  @Test("Back after typing in a field leaves the editor")
  func backAfterTyping() async throws {
    let screen = try await opened()
    defer { screen.close() }
    try screen.clickControl(at: Self.edit)
    try await settle(screen, untilShowing: "Delete Agent…")
    let description = try #require(
      screen.allViews.compactMap { $0 as? NSTextField }.first { $0.isEditable })
    try screen.click(description)
    try screen.type("better")
    try await pause(screen)
    try screen.clickControl(at: 0)
    try await settle(screen, untilShowing: "Yours")
  }

  @Test("Delete asks first; an agent in use says so and can be forced")
  func deleting() async throws {
    SystemSideEffects.install()
    defer { SystemSideEffects.reset() }
    let server = agentsServer()
    server.route(
      "/v1/agents/a1", method: "DELETE",
      .json(
        #"{"error":{"code":"agent_in_use","message":"2 session(s) still use 'r'"},"sessions_in_use":"2"}"#,
        status: 409))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.edit)
    try await settle(screen, untilShowing: "Delete Agent…")
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, untilShowing: "2 session(s) still use 'r'")
    server.route("/v1/agents/a1", method: "DELETE", .json(#"{"id":"a1","deleted":true}"#))
    try screen.clickControl(at: 1)
    try await settle(screen, untilShowing: "Yours")
    let attempts = server.requests("DELETE", "/v1/agents/a1")
    #expect(attempts.count == 2)
    #expect(attempts.last?.url.contains("force=true") == true)
  }

  @Test("Without the server's agent detail there's no editor")
  func readOnly() async throws {
    let screen = try await opened(canEdit: false)
    defer { screen.close() }
    #expect(try !screen.shows("Edit…"))
  }

  @Test("A list that can't be read says why, and so does a config")
  func failures() async throws {
    let server = agentsServer()
    server.route("/v1/agents/a1/config", .json(#"{"detail":"nope"}"#, status: 500))
    let screen = try await opened(server)
    defer { screen.close() }
    try screen.clickControl(at: Self.edit)
    try await settle(
      screen, untilShowing: "The server returned HTTP 500. Check that it is running and try again.")
  }

  @Test("A bundle that can't be read says so; a readable one uploads")
  func bundles() async throws {
    let server = agentsServer()
    server.route("/v1/agents", method: "POST", .json(#"{"id":"a9","name":"Bundle"}"#))
    let connection = try await signedInStore(server)
    let store = try #require(connection.customAgents())
    let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
      do {
        try FileManager.default.removeItem(at: folder)
      } catch {
        Issue.record("could not remove the test folder: \(error)")
      }
    }
    let missing = await CustomAgentsBundle.install(
      folder.appending(path: "missing.tar.gz"), store: store)
    #expect(missing == nil)
    #expect(store.error?.message.hasPrefix("Could not read missing.tar.gz") == true)

    let file = folder.appending(path: "agent.tar.gz")
    try Data([1, 2, 3]).write(to: file)
    let installed = await CustomAgentsBundle.install(file, store: store)
    #expect(installed?.id == "a9")
    #expect(server.requests("POST", "/v1/agents").count == 1)
  }

  @Test("In a new session, Create hands the form back unsaved")
  func aDraftIsHandedBack() async throws {
    let server = agentsServer()
    let connection = try await signedInStore(server)
    let store = try #require(connection.customAgents())
    final class Result { var drafts: [AgentDraft] = [] }
    let result = Result()
    let screen = OffscreenWindow(
      Color.clear.sheet(isPresented: .constant(true)) {
        CreateAgentContainer(
          store: store, allowsImport: false, created: { _ in },
          drafted: { result.drafts.append($0) }, cancel: {})
      }, width: 700, height: 700)
    defer { screen.close() }
    try await settle(screen, untilShowing: "Add MCP Server")
    try fillIn("mine", in: screen)
    try screen.clickControl(at: screen.controlFrames.count - 1)
    try await settle(screen, until: "the draft") { !result.drafts.isEmpty }
    #expect(result.drafts.first?.name == "mine")
    #expect(server.requests("POST", "/v1/agents").isEmpty)
  }
}
