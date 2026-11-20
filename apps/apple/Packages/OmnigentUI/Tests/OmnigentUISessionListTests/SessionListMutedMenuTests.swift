#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// A muted row's read and unread items.
  @Suite("Sidebar: a muted row's menu", .serialized)
  @MainActor
  struct SessionListMutedMenuTests {
    @Test("A muted row with activity not seen offers Mark as read, as the web's")
    func mutedUnseen() throws {
      var state = SidebarFixture.state
      state.list.sessions[1].isMuted = true
      let spy = SidebarSpy(state)
      spy.offersMute = true
      spy.mutedUnseen = ["beta"]
      let screen = OffscreenWindow(SidebarHarness(spy: spy), width: 300, height: 700)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: SidebarFixture.betaRow))
      #expect(menu.item(named: "Mark as unread") == nil)
      try screen.choose("Mark as read", in: menu)
      #expect(spy.calls == ["unread beta false"])
    }
  }
#endif
