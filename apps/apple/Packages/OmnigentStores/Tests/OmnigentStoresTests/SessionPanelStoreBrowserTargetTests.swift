import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The session's browser choice (`omnigent.browser_target`) as the panel store reads and saves
/// it for the toolbar's chip.
@Suite("Session panel: browser target")
@MainActor
struct SessionPanelStoreBrowserTargetTests {
  private let server = RouteServer()
  private let sessionPath = "/v1/sessions/conv_a"

  private func panel(offersAgentBrowser: Bool) async throws -> SessionPanelStore {
    let features = #"{"agent_browser_devtools":\#(offersAgentBrowser)}"#
    server.route(
      "/v1/info",
      .json(#"{"single_user":true,"accounts_enabled":false,"features":\#(features)}"#))
    let store = try await connectedStore(server)
    return try #require(store.makePanelStore("conv_a"))
  }

  @Test("Reads the label where the server offers the agent browser, and not otherwise")
  func load() async throws {
    server.route(
      sessionPath, method: "GET",
      .json(#"{"id":"conv_a","labels":{"omnigent.browser_target":"remote"}}"#))
    let offered = try await panel(offersAgentBrowser: true)
    await offered.loadBrowserTarget()
    #expect(offered.offersAgentBrowser)
    #expect(offered.browserTarget == .remote)
    #expect(offered.browserTargetError == nil)

    let plain = try await panel(offersAgentBrowser: false)
    let readsBefore = server.requests(to: sessionPath).count
    await plain.loadBrowserTarget()
    #expect(plain.browserTarget == nil)
    #expect(server.requests(to: sessionPath).count == readsBefore)
  }

  @Test("A failed read keeps the last choice and records why")
  func failedRead() async throws {
    server.route(sessionPath, method: "GET", .json(#"{"id":"conv_a","labels":{}}"#))
    let panel = try await panel(offersAgentBrowser: true)
    await panel.loadBrowserTarget()
    #expect(panel.browserTarget == .auto)
    server.fail(sessionPath, method: "GET")
    await panel.loadBrowserTarget()
    #expect(panel.browserTarget == .auto)
    #expect(panel.browserTargetError != nil)
  }

  @Test("Saving writes the label; a 403 puts the old choice back and says forbidden")
  func save() async throws {
    server.route(sessionPath, method: "GET", .json(#"{"id":"conv_a","labels":{}}"#))
    server.route(sessionPath, method: "PATCH", .json(#"{"id":"conv_a"}"#))
    let panel = try await panel(offersAgentBrowser: true)
    await panel.loadBrowserTarget()
    #expect(await panel.setBrowserTarget(.remote) == nil)
    #expect(panel.browserTarget == .remote)
    let patch = try #require(server.requests(to: sessionPath, method: "PATCH").last)
    let labels = try #require(try server.body(of: patch)["labels"] as? [String: String])
    #expect(labels == ["omnigent.browser_target": "remote"])

    server.fail(sessionPath, method: "PATCH", status: 403, detail: "owner only")
    let refused = await panel.setBrowserTarget(.local)
    guard case .Session(.forbidden, _, _, _, _) = refused else {
      Issue.record("expected forbidden, got \(String(describing: refused))")
      return
    }
    #expect(panel.browserTarget == .remote)
  }
}
