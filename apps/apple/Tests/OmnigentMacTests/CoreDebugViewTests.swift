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
