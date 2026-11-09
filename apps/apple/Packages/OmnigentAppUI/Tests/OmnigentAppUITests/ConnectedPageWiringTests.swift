import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import Testing

@testable import OmnigentAppUI

/// What a window's pages do to its navigation.
extension ConnectedWindowFlowTests {
  @Test("A session on the Usage page opens in the window")
  func usageOpensSession() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/usage",
      .json(
        #"{"object":"usage_report","cost_today":1.0,"daily_costs":[],"sessions":[{"id":"conv_b","created_at":1793700000,"updated_at":1793750000,"title":"Fix","cost_usd":1.25,"models":{"sonnet":1.0},"harness":"claude-code"}]}"#
      ))
    let mounted = try await mounted(server, page: .usage)
    defer { mounted.screen.close() }
    try await settle(mounted.screen, untilShowing: "Fix")
    let row = try #require(mounted.screen.controlFrames.last)
    try mounted.screen.click(CGPoint(x: row.midX, y: row.midY))
    try await settle(mounted.screen, until: "the session") {
      mounted.selection.page == .session("conv_b")
    }
  }

  @Test("Answering the shell alert closes the shell, or keeps it")
  func closeShellAlert() async throws {
    let mounted = try await mounted()
    defer {
      mounted.screen.close()
      SystemSideEffects.reset()
    }
    let group = mounted.session.tabs.group("conv_a")
    let kept = group.open(.terminal(sessionID: "conv_a", terminalID: "t1"), title: "zsh")
    SystemSideEffects.answer(alert: .alertSecondButtonReturn)
    group.closingShell = kept.id
    try await settle(mounted.screen, until: "Cancel") { group.closingShell == nil }
    #expect(group.tabs.contains { $0.id == kept.id })

    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    group.closingShell = kept.id
    try await settle(mounted.screen, until: "Close Shell") {
      !group.tabs.contains { $0.id == kept.id }
    }
  }

  @Test("Control-Command-1 opens the first pinned session")
  func pinnedShortcut() async throws {
    let server = threeSessionServer()
    let pinned =
      #"{"id":"conv_b","status":"idle","created_at":1,"updated_at":5,"host_id":"mac","workspace":"/w","permission_level":4,"archived":false,"pinned":true,"labels":{"omnigent.pinned":"1"}}"#
    let row = sessionRow("conv_a", host: "mac", workspace: "/a", updatedAt: 3)
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(row),\#(pinned)],"has_more":false}"#))
    let mounted = try await mounted(server)
    defer { mounted.screen.close() }
    try await settle(mounted.screen, until: "the pin") {
      mounted.session.connection.sessionList.session("conv_b")?.isPinned == true
    }
    let handled = try pressShortcut(
      mounted.screen, keyCode: 18, characters: "1", modifiers: [.control, .command])
    #expect(handled)
    try await settle(mounted.screen, until: "the pinned session") {
      mounted.selection.page == .session("conv_b")
    }
  }

  @Test("A failed edit in the sidebar shows an alert whose OK clears it")
  func editErrorAlert() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_b", method: "PATCH", .json(#"{"detail":"no"}"#, status: 422))
    let mounted = try await mounted(server)
    defer { mounted.screen.close() }
    let list = mounted.session.connection.sessionList
    await list.setPinned("conv_b", true)
    #expect(list.editError != nil)
    try await settle(mounted.screen, until: "OK to clear it") { list.editError == nil }
  }
}
