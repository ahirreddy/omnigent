import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// Key equivalents the mounted window answers itself, with no menu item behind them.
extension ConnectedWindowFlowTests {
  /// Three sessions, the first two pinned.
  private func pinnedServer() -> AppServer {
    let server = threeSessionServer()
    let rows = ["conv_a", "conv_b", "conv_c"].enumerated().map { index, id in
      let row = sessionRow(id, host: "mac", workspace: "/work/\(id)", updatedAt: Int64(30 - index))
      guard id != "conv_c" else { return row }
      return #"{"pinned":true,"labels":{"omnigent.pinned":"1"},"# + row.dropFirst()
    }
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
    return server
  }

  private func pressPinned(_ digit: String, keyCode: UInt16, in mounted: Mounted) throws -> Bool {
    try pressShortcut(
      mounted.screen, keyCode: keyCode, characters: digit, modifiers: [.command, .control])
  }

  @Test("Control-Command-digit opens the pinned session in that place, and no other")
  func pinnedSessionKeys() async throws {
    let mounted = try await mounted(pinnedServer(), page: nil)
    defer { mounted.screen.close() }
    let pinned = SidebarNavigationOrder.pinnedIDs(mounted.view.sidebarState)
    try #require(Set(pinned) == ["conv_a", "conv_b"], "the fixture's pins: \(pinned)")

    #expect(try pressPinned("2", keyCode: 19, in: mounted))
    try await settle(mounted.screen, until: "the second pin") {
      mounted.selection.page == .session(pinned[1])
    }
    #expect(try pressPinned("1", keyCode: 18, in: mounted))
    try await settle(mounted.screen, until: "the first pin") {
      mounted.selection.page == .session(pinned[0])
    }
    // The third place has no pin: the key is taken, and the window stays where it is.
    #expect(try pressPinned("3", keyCode: 20, in: mounted))
    try await Task.sleep(for: .milliseconds(100))
    #expect(mounted.selection.page == .session(pinned[0]))
  }
}
