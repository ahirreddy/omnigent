#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("MCP and integrations, clicked", .serialized)
  @MainActor
  struct SettingsServicesTests {
    private let log = ActionLog()
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-services-\(UUID())"))
    }

    private func actions(connects: Bool = true, test: String? = "3 tools OK")
      -> ServerSettingsActions
    {
      var actions = ServerSettingsActions()
      let log = log
      actions.connectMCP = {
        log.record("connect \($0.id) [\($1)]")
        return connects
      }
      actions.disconnectMCP = { log.record("disconnect \($0.id)") }
      actions.testMCP = {
        log.record("test \($0.id)")
        return test
      }
      actions.openInBrowser = { log.record("browser \($0.rawValue)") }
      actions.disconnectProvider = { log.record("provider-off \($0.id)") }
      return actions
    }

    private func tokenSheet(
      connects: Bool = true, errorMessage: String? = nil
    ) throws -> OffscreenWindow<some View> {
      let service = MCPServiceRow(id: "docs", name: "Docs", isConnected: false, acceptsToken: true)
      let actions = actions(connects: connects)
      let screen = settingsForm(store: store) {
        MCPPane(services: [service], actions: actions, errorMessage: errorMessage)
      }
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      try #require(screen.window.attachedSheet != nil)
      return screen
    }

    @Test("a pasted token is sent without its stray spaces or newline")
    func tokenIsTrimmed() async throws {
      let screen = try tokenSheet()
      defer { screen.close() }
      let field = try #require(screen.secureFields.first)
      try screen.replaceText(in: field, with: " secret ")
      try screen.clickButton(at: 1)
      try await screen.letTasksRun()
      #expect(log.entries == ["connect docs [secret]"])
    }

    @Test("a token pasted with its trailing newline isn't a different token, or a blank one")
    func pastedToken() {
      #expect(MCPPane.cleanedToken("secret\n") == "secret")
      #expect(MCPPane.cleanedToken(" \t\n").isEmpty)
    }

    @Test("Connect is off until there's a token, and connecting closes the sheet")
    func connects() async throws {
      let screen = try tokenSheet()
      defer { screen.close() }
      #expect(screen.buttonFrames.count == 1, "only Cancel while the token is empty")
      let field = try #require(screen.secureFields.first)
      try screen.replaceText(in: field, with: "   ")
      #expect(screen.buttonFrames.count == 1, "spaces aren't a token")
      try screen.replaceText(in: field, with: "secret")
      try screen.clickButton(at: 1)
      try await screen.letTasksRun()
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
    }

    @Test("a refused token says why beside the field, and typing clears it")
    func refusedToken() async throws {
      let screen = try tokenSheet(connects: false, errorMessage: "Bad token")
      defer { screen.close() }
      let field = try #require(screen.secureFields.first)
      try screen.replaceText(in: field, with: "secret")
      try screen.clickButton(at: 1)
      try await screen.letTasksRun()
      #expect(screen.window.attachedSheet != nil, "the sheet stays to try again")
      #expect(log.entries.count == 1)
      #expect(try screen.shows("Bad token"))
      try screen.replaceText(in: field, with: "other")
      #expect(try !screen.shows("Bad token"))
    }

    @Test("a refusal with no reason from the server still says something")
    func refusedWithoutReason() async throws {
      let screen = try tokenSheet(connects: false)
      defer { screen.close() }
      try screen.replaceText(in: try #require(screen.secureFields.first), with: "secret")
      try screen.clickButton(at: 1)
      try await screen.letTasksRun()
      #expect(try screen.shows("The token was not accepted."))
    }

    @Test("Cancel closes the sheet and forgets the token")
    func cancelForgets() throws {
      let screen = try tokenSheet()
      defer { screen.close() }
      let field = try #require(screen.secureFields.first)
      try screen.replaceText(in: field, with: "secret")
      try screen.clickButton(at: 0)
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
      #expect(log.entries.isEmpty)
      try screen.clickControl(at: 0)
      screen.settle(0.3)
      #expect(screen.secureFields.first?.stringValue.isEmpty == true)
    }

    @Test("a connected service can be tested and disconnected, and forgets the test")
    func connectedService() async throws {
      let service = MCPServiceRow(
        id: "docs", name: "Docs", detail: "The docs", isConnected: true, tools: ["a"],
        canDisconnect: true)
      let actions = actions()
      let screen = settingsForm(store: store) { MCPPane(services: [service], actions: actions) }
      defer { screen.close() }
      #expect(try screen.shows("The docs \u{00B7} Connected \u{00B7} 1 tool"))
      try screen.clickControl(at: 0)
      try await screen.letTasksRun()
      #expect(log.entries == ["test docs"])
      #expect(try screen.shows("3 tools OK"))
      try screen.clickControl(at: 1)
      #expect(log.entries.last == "disconnect docs")
      #expect(try !screen.shows("3 tools OK"))
    }

    @Test("a browser service opens the browser; no services says so")
    func browserService() throws {
      let service = MCPServiceRow(
        id: "o", name: "OAuth", isConnected: false, connectsInBrowser: true)
      let actions = actions()
      let screen = settingsForm(store: store) { MCPPane(services: [service], actions: actions) }
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(log.entries == ["browser mcp"])
      let none = settingsForm(store: store) { MCPPane(services: [], actions: actions) }
      defer { none.close() }
      #expect(try none.shows("No MCP services."))
    }

    @Test("integrations connect in the browser and disconnect the right account")
    func integrations() throws {
      let rows = [
        ProviderConnectionRow(id: "gh", name: "GitHub", isConnected: true, account: "ada"),
        ProviderConnectionRow(id: "db", name: "Databricks", isConnected: false),
      ]
      let actions = actions()
      let screen = settingsForm(store: store) {
        IntegrationsPane(connections: rows, actions: actions)
      }
      defer { screen.close() }
      #expect(try screen.shows("Connected as ada"))
      try screen.clickControl(at: 0)
      try screen.clickControl(at: 1)
      #expect(log.entries == ["provider-off gh", "browser integrations"])
      let none = settingsForm(store: store) { IntegrationsPane(connections: [], actions: actions) }
      defer { none.close() }
      #expect(try none.shows("No integrations."))
    }
  }
#endif
