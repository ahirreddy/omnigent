#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The nesting fixture drawn as the app draws it, written as PNGs where
  /// `OMNIGENT_UI_RENDER_DIR` names a directory.
  @Suite("Sidebar nesting: the fixture drawn", .serialized)
  @MainActor
  struct SidebarNestingRenderTests {
    @Test("draws the fixture sidebar", arguments: ["dark", "light"])
    func render(_ scheme: String) throws {
      let spy = SidebarSpy(SidebarNestingFixture.state)
      UserDefaults.standard.set(
        SidebarNestingFixture.project.id, forKey: SidebarNavigationOrder.expandedProjectsKey)
      spy.selection = .session("keys")
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy), width: 320, height: 1040,
        appearance: scheme == "dark" ? .darkAqua : .aqua)
      defer { screen.close() }
      try screen.hoverRow(try #require(try screen.listRow(of: "loose")))
      screen.settle(0.3)
      let rendered = try RenderSupport.capture(screen.host)
      #expect(RenderSupport.inkCoverage(rendered) > 0.01)
      try RenderSupport.write(rendered, name: "sidebar-nesting-\(scheme)")
    }
  }
#endif
