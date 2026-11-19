#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The nesting and projects fixtures drawn as the app draws them, written as PNGs where
  /// `OMNIGENT_UI_RENDER_DIR` names a directory.
  @Suite("Sidebar nesting: the fixtures drawn", .serialized)
  @MainActor
  struct SidebarNestingRenderTests {
    @Test("draws the nesting fixture", arguments: ["dark", "light"])
    func render(_ scheme: String) throws {
      let spy = SidebarSpy(SidebarNestingFixture.state)
      UserDefaults.standard.set(
        SidebarNestingFixture.project.id, forKey: SidebarNavigationOrder.expandedProjectsKey)
      spy.selection = .session("keys")
      try draw(spy, scheme: scheme, hovering: "loose", name: "sidebar-nesting-\(scheme)")
    }

    @Test("draws the projects fixture", arguments: ["dark", "light"])
    func renderProjects(_ scheme: String) throws {
      let spy = SidebarSpy(SidebarProjectsFixture.state)
      UserDefaults.standard.set(
        SidebarProjectsFixture.expanded.joined(separator: "\n"),
        forKey: SidebarNavigationOrder.expandedProjectsKey)
      spy.selection = .session("plan")
      try draw(spy, scheme: scheme, hovering: "rotate", name: "sidebar-projects-\(scheme)")
    }

    private func draw(_ spy: SidebarSpy, scheme: String, hovering: String, name: String) throws {
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy), width: 320, height: 1040,
        appearance: scheme == "dark" ? .darkAqua : .aqua)
      defer { screen.close() }
      try screen.hoverRow(try #require(try screen.listRow(of: hovering)))
      screen.settle(0.3)
      let rendered = try RenderSupport.capture(screen.host)
      #expect(RenderSupport.inkCoverage(rendered) > 0.01)
      try RenderSupport.write(rendered, name: name)
    }
  }
#endif
