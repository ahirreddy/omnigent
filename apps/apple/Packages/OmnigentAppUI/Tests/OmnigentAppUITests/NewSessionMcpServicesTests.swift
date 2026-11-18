import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The MCPs chip under the new-session composer (the web's `McpRegistryLaunchPicker`): shown
/// where `/v1/info` lists the `mcp` connection, remembered across starts, and sent at launch.
@MainActor
@Suite("New session MCP services", .timeLimit(.minutes(1)))
struct NewSessionMcpServicesTests {
  /// A server with the MCP registry and three services: one connected, one that takes a token,
  /// one that signs in through the browser.
  private func registryServer() -> AppServer {
    let server = newSessionServer()
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"enabled_connections":["mcp"]}"#))
    server.route(
      "/v1/mcp-registry/services",
      .json(
        #"{"data":[{"id":"docs","title":"Docs","auth":"none","connected":true,"tools":[]},"#
          + #"{"id":"wiki","title":"Wiki","auth":"bearer","connected":false,"tools":[]},"#
          + #"{"id":"tracker","title":"Tracker","auth":"oauth","connected":false,"tools":[]}]}"#))
    return server
  }

  private func loaded(_ server: AppServer, remembered: [String] = []) async throws
    -> (NewSessionForm, CreationStore)
  {
    let connection = try await signedInStore(server)
    let creation = try #require(connection.creation())
    let form = try isolatedForm()
    form.preferences.set(remembered, forKey: NewSessionForm.mcpServicesKey)
    await form.load(creation)
    form.selectFolder(creation, "/work/app")
    return (form, creation)
  }

  @Test("The chip lists the services with what each needs, and a choice is sent and kept")
  func choosesAndSends() async throws {
    let server = registryServer()
    let (form, creation) = try await loaded(server, remembered: ["gone"])
    let chip = try #require(form.mcpChip(creation))
    #expect(chip.phase == .loaded)
    #expect(
      chip.services.map(\.status) == [
        "Connected", "Connect your account in settings", "Needs sign-in",
      ])
    #expect(chip.services.map(\.canToggle) == [true, false, false])
    #expect(chip.chipTitle == "MCPs", "a remembered service the registry dropped is not counted")

    form.toggleMcpService("docs", enabled: true)
    #expect(form.mcpChip(creation)?.chipTitle == "MCPs \u{00B7} 1")
    #expect(
      form.preferences.stringArray(forKey: NewSessionForm.mcpServicesKey) == ["gone", "docs"])

    form.start(creation, text: "")
    try await eventually("the create request") { !server.requests("POST", "/v1/sessions").isEmpty }
    let body = try #require(try server.posted("/v1/sessions").first)
    #expect(body["mcp_registry_services"] as? [String] == ["docs"])
  }

  @Test("A server without the registry shows no chip and sends no services")
  func noRegistry() async throws {
    let server = newSessionServer()
    let (form, creation) = try await loaded(server, remembered: ["docs"])
    #expect(form.mcpChip(creation) == nil)
    #expect(form.mcpProblem(creation) == nil)
    #expect(form.mcpLaunchServices(creation).isEmpty)
    #expect(server.requests("GET", "/v1/mcp-registry/services").isEmpty)
  }

  @Test("Chosen services wait for a registry that could not be read")
  func unreadableRegistry() async throws {
    let server = registryServer()
    server.route(
      "/v1/mcp-registry/services", .json(#"{"detail":"registry down"}"#, status: 503))
    let (form, creation) = try await loaded(server, remembered: ["docs"])
    #expect(form.mcpChip(creation)?.chipTitle == "MCPs \u{00B7} 1", "the remembered count")
    #expect(form.mcpProblem(creation)?.hasPrefix("Could not load MCP services") == true)
    form.toggleMcpService("docs", enabled: false)
    #expect(form.mcpProblem(creation) == nil)
  }
}
