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

/// Settings > Servers: which server and pane it shows, and what leaves the window.
@MainActor
@Suite("Server settings window", .serialized, .timeLimit(.minutes(1)))
struct ServerSettingsContainerTests {
  private final class Opened {
    var urls: [URL] = []
    var sessions: [String] = []
    var succeeds = true
  }

  private struct Page {
    let screen: OffscreenWindow<ServerSettingsContainer>
    let navigator: SettingsNavigator
    let opened: Opened
    let connection: ConnectionStore
  }

  private func page(
    _ server: AppServer = settingsServer(), info: String = everyPageInfo,
    also other: ConnectionStore? = nil
  ) async throws -> Page {
    SystemSideEffects.install()
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(info))
    server.route("/v1/me", .json(#"{"user_id":"ada","is_admin":true}"#))
    let navigator = SettingsNavigator()
    let opened = Opened()
    let container = ServerSettingsContainer(
      connections: { [connection] + (other.map { [$0] } ?? []) },
      opener: ExternalURLOpener { url in
        opened.urls.append(url)
        return opened.succeeds
      },
      navigator: navigator,
      openSession: { _, id in opened.sessions.append(id) })
    let screen = OffscreenWindow(container, width: 1000, height: 800)
    try await pause(screen, .milliseconds(100))
    return Page(screen: screen, navigator: navigator, opened: opened, connection: connection)
  }

  private func show(_ pane: ServerSettingsPane, url: String? = nil, on page: Page) async throws {
    page.navigator.show(.server(url: url, pane: pane))
    try await pause(page.screen, .milliseconds(150))
  }

  /// Clicks a control of the pane. Their frames leave out the sidebar, which sits beside them.
  private func clickInPane(_ index: Int, on page: Page) throws {
    let frame = page.screen.controlFrames[index]
    try page.screen.click(CGPoint(x: frame.midX + 200, y: frame.midY))
  }

  @Test("It opens on the first signed-in server, and a request moves it to a pane")
  func showsARequest() async throws {
    let page = try await page()
    defer { page.screen.close() }
    #expect(try page.screen.shows("Signed in as"))
    try await show(.mcp, on: page)
    #expect(page.navigator.serverRequest == nil, "the request was taken")
    try await settle(page.screen, untilShowing: "Docs")
    #expect(try !page.screen.shows("Signed in as"))
  }

  @Test("A request can name another signed-in server, however its address is spelled")
  func anotherServer() async throws {
    let otherServer = settingsServer()
    let other = try await signedInStore(otherServer, url: "http://127.0.0.1:7777")
    otherServer.route("/v1/info", .json(everyPageInfo))
    let page = try await page(also: other)
    defer { page.screen.close() }
    #expect(otherServer.requests("GET", "/v1/mcp-registry/services").isEmpty)
    try await show(.mcp, url: "HTTP://127.0.0.1:7777/", on: page)
    try await settle(page.screen, until: "the other server's services") {
      !otherServer.requests("GET", "/v1/mcp-registry/services").isEmpty
    }
  }

  @Test("A browser-only MCP service opens the server's web settings; a failure says so")
  func connectingInTheBrowser() async throws {
    let server = settingsServer()
    server.route(
      "/v1/mcp-registry/services",
      .json(
        #"{"data":[{"id":"empty","title":"Empty","auth":"bearer","connected":false},{"id":"web","title":"Web","auth":"oauth","connected":false}],"has_more":false}"#
      ))
    let page = try await page(server)
    defer { page.screen.close() }
    try await show(.mcp, on: page)
    try await settle(page.screen, untilShowing: "Web")
    page.opened.succeeds = false
    try clickInPane(2, on: page)
    try await settle(page.screen, untilShowing: "Could not open", contains: true)
    #expect(page.opened.urls.map(\.absoluteString) == ["http://127.0.0.1:6767/settings/mcp"])
  }

  @Test("A provider that isn't connected opens the integrations page")
  func anIntegrationInTheBrowser() async throws {
    let server = settingsServer()
    server.route(
      "/v1/connections/github/status", .json(#"{"enabled":true,"connected":false}"#))
    let page = try await page(server)
    defer { page.screen.close() }
    try await show(.integrations, on: page)
    try await settle(page.screen, untilShowing: "Not connected")
    try clickInPane(1, on: page)
    try await settle(page.screen, until: "the link") { !page.opened.urls.isEmpty }
    #expect(page.opened.urls.first?.path() == "/settings/integrations")
  }

  @Test("Sign Out signs the server out, and the page lets it go")
  func signingOut() async throws {
    let page = try await page()
    defer { page.screen.close() }
    try clickInPane(1, on: page)
    try await settle(page.screen, until: "the sign out") { !page.connection.isSignedIn }
  }

  @Test("Harnesses and Custom Agents show over the server's own stores")
  func hostedPanes() async throws {
    let server = settingsServer()
    server.route("/v1/harnesses", .json(#"{"data":[{"id":"claude-native","label":"Claude"}]}"#))
    server.route("/v1/agents", .json(#"{"data":[],"has_more":false}"#))
    let page = try await page(
      server,
      info:
        #"{"single_user":true,"agent_install":true,"agent_detail":true,"features":{"custom_agents_settings_ui":true}}"#
    )
    defer { page.screen.close() }
    try await show(.harnesses, on: page)
    try await settle(page.screen, until: "the harnesses") {
      !server.requests("GET", "/v1/harnesses").isEmpty
    }
    try await show(.customAgents, on: page)
    try await settle(page.screen, until: "the agents") {
      !server.requests("GET", "/v1/agents").isEmpty
    }
    #expect(page.navigator.serverRequest == nil)
  }
}
