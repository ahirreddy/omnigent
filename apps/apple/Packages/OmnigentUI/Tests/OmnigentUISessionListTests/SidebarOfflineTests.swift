#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The sidebar while its list is this device's saved copy, because the server cannot be reached.
  @Suite("Sidebar: offline", .serialized)
  @MainActor
  struct SidebarOfflineTests {
    @Test("The saved sessions show with a quiet offline line and Retry, in place of a failure")
    func offlineLine() throws {
      var state = SidebarViewState(
        list: SessionListViewState(
          sessions: [SidebarFixture.beta], phase: .failed(message: "Couldn't refresh")))
      state.savedListNotice = .offline("Offline \u{2014} showing saved sessions")
      let spy = SidebarSpy(state)
      let screen = OffscreenWindow(
        AnyView(SidebarHarness(spy: spy)), width: 340, height: 800)
      defer { screen.close() }
      #expect(try screen.shows("Offline \u{2014} showing saved sessions"))
      #expect(try screen.shows("Beta"))
      #expect(try !screen.shows("Couldn't refresh"))
      try screen.clickControl(at: screen.controlFrames.count - 1)
      #expect(spy.calls == ["retry"])
    }

    @Test("While connecting, the saved sessions show with a line saying they are being updated")
    func refreshingLine() throws {
      var state = SidebarViewState(list: SessionListViewState(sessions: [SidebarFixture.beta]))
      state.savedListNotice = .refreshing("Updating saved sessions\u{2026}")
      let screen = OffscreenWindow(
        AnyView(SidebarHarness(spy: SidebarSpy(state))), width: 340, height: 800)
      defer { screen.close() }
      #expect(try screen.shows("Updating saved sessions\u{2026}"))
      #expect(try screen.shows("Beta"))
      #expect(try !screen.shows("Retry"))
    }
  }
#endif
