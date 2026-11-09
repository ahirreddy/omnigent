import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// Pages that read their data again while they show, and stop once they're gone.
@MainActor
@Suite("Page refreshes", .serialized, .timeLimit(.minutes(1)))
struct PageRefreshTests {
  /// How many times `path` was read.
  private func reads(_ server: AppServer, _ path: String) -> Int {
    server.requests("GET", path).count
  }

  /// Waits for two more reads of `path`, then closes the page and sees the reads stop.
  private func expectRefreshing<Content: View>(
    _ screen: OffscreenWindow<Content>, _ server: AppServer, path: String
  ) async throws {
    let before = reads(server, path)
    try await settle(screen, until: "\(path) read again") { reads(server, path) >= before + 2 }
    screen.close()
    try await Task.sleep(for: .milliseconds(40))
    let afterClosing = reads(server, path)
    try await Task.sleep(for: .milliseconds(40))
    #expect(reads(server, path) == afterClosing)
  }

  @Test("The Agents tab reads the tree again while it shows")
  func agentTree() async throws {
    let server = threeSessionServer()
    let connection = try await signedInStore(server)
    let store = ConversationStore(sessionID: "conv_a", core: try #require(connection.core))
    let page = AgentTreePanelHost(
      conversation: store, open: { _ in }, refreshInterval: .milliseconds(5))
    let screen = OffscreenWindow(page, width: 400, height: 300)
    try await expectRefreshing(screen, server, path: "/v1/sessions/conv_a/child_sessions")
  }

  @Test("Canvas reads its sessions again while it shows")
  func canvas() async throws {
    let server = threeSessionServer()
    let connection = try await signedInStore(server)
    server.route("/v1/info", .json(#"{"single_user":true,"features":{"canvas":true}}"#))
    _ = await connection.pages?.loadOffered()
    let screen = OffscreenWindow(
      CanvasAdapter(
        connection: connection, open: { _ in }, newSession: {},
        readsAgainEvery: .milliseconds(5)),
      width: 1000, height: 700)
    try await expectRefreshing(screen, server, path: "/v1/sessions")
  }

  @Test("An automation's page reads its runs again while it shows")
  func automationRuns() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/scheduled-tasks", method: "GET",
      .json(
        #"{"scheduled_tasks":[{"id":"t1","name":"Standup","prompt":"Summarize","rrule":"FREQ=DAILY;BYHOUR=9;BYMINUTE=0","agent_id":"ag_claude","timezone":"UTC","state":"active","next_run_at":"2099-11-05T09:00:00Z"}]}"#
      ))
    let connection = try await signedInStore(server)
    let pages = try #require(connection.pages)
    await pages.loadAutomations()
    let automation = try #require(pages.automations.value?.first)
    let screen = OffscreenWindow(
      AutomationDetailAdapter(
        pages: pages, automation: automation, open: { _ in }, back: {}, edit: {},
        readsRunsEvery: .milliseconds(5)),
      width: 800, height: 500)
    try await expectRefreshing(screen, server, path: "/v1/scheduled-tasks/t1/runs")
  }
}
