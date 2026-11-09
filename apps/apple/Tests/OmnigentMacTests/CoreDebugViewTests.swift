import AppKit
import OmnigentCoreFFI
import OmnigentStores
import OmnigentViewTesting
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// Suites that use `SystemSideEffects`, which replaces window ordering and sheets for the whole
/// process, stay out of the VM run: its real sheet and window suites need the real ones.
enum HostedOffscreen {
  static var isAllowed: Bool { !VirtualMachine.isPresent }
}

/// The core inspector, on the core's offline demo server.
@MainActor
@Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
struct CoreDebugViewTests {
  private func connectedStore() async throws -> ConnectionStore {
    try await PreviewData.connectedDemoStore()
  }

  @Test func phasesReadPlainly() {
    #expect(CoreDebugView.describe(.disconnected) == "disconnected")
    #expect(CoreDebugView.describe(.discovering(serverUrl: "u")) == "discovering u")
    #expect(CoreDebugView.describe(.connecting(baseUrl: "u")) == "connecting to u")
    #expect(CoreDebugView.describe(.signingIn(baseUrl: "u")) == "signing in to u")
  }

  @Test func linkStatesReadPlainly() {
    #expect(CoreDebugView.describe(LinkState.idle) == "idle")
    #expect(CoreDebugView.describe(LinkState.connecting) == "connecting")
    #expect(CoreDebugView.describe(LinkState.live) == "live")
    #expect(CoreDebugView.describe(LinkState.closed) == "closed")
    #expect(CoreDebugView.describe(LinkState.stopped) == "stopped")
  }

  @Test func aFailedPhaseAndLinkSayWhy() {
    let error = CoreError.InvalidState(message: "broken")
    #expect(CoreDebugView.describe(.failed(serverUrl: "u", error: error)).hasPrefix("failed u: "))
    #expect(CoreDebugView.describe(LinkState.failed(error: error)).hasPrefix("failed: "))
    let reconnecting = LinkState.reconnecting(reason: error, failures: 3, delayMs: 500)
    #expect(CoreDebugView.describe(reconnecting).contains("after 3 failures"))
  }

  /// `-OmnigentCoreDebugSession` preselects a session; its rows open in the core.
  @Test func aPreselectedSessionOpensItsConversation() async throws {
    let store = try await connectedStore()
    let key = "OmnigentCoreDebugSession"
    UserDefaults.standard.set("demo-notes", forKey: key)
    defer { UserDefaults.standard.removeObject(forKey: key) }
    let screen = OffscreenWindow(CoreDebugView().environment(store), width: 720, height: 600)
    defer { screen.close() }
    for _ in 0..<200 where store.conversations["demo-notes"] == nil {
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(store.conversations["demo-notes"] != nil)
    try await Task.sleep(for: .milliseconds(100))
    let lists = screen.allViews.compactMap { $0 as? NSTableView }
    #expect(lists.count == 2, "the sessions and the conversation's rows")
    for list in lists {
      // An offscreen table makes its rows only when asked, as a person scrolling them would.
      for row in 0..<list.numberOfRows { _ = list.rowView(atRow: row, makeIfNecessary: true) }
    }
    screen.settle()
    #expect(lists.contains { $0.numberOfRows == store.sessionList.visible.count })
    let conversation = try #require(store.conversations["demo-notes"])
    #expect(lists.contains { $0.numberOfRows == conversation.rows.count })
  }

  @Test func theInspectorShowsTheConnectedCoreAndItsSessions() async throws {
    let store = try await connectedStore()
    #expect(store.isSignedIn)
    #expect(CoreDebugView.describe(store.phase).hasPrefix("connected to "))
    let screen = OffscreenWindow(CoreDebugView().environment(store), width: 720, height: 600)
    defer { screen.close() }
    screen.settle()
    #expect(screen.window.isVisible)
    #expect(!screen.allViews.isEmpty)
  }
}
