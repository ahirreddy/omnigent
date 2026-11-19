#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What drawing a long sidebar costs: its first frame builds rows, not their menus.
  @Suite("Sidebar: the cost of its rows", .serialized)
  @MainActor
  struct SidebarRowCostTests {
    private func sessions(_ count: Int) -> [SessionSummary] {
      (0..<count).map { index in
        SessionSummary(
          id: "s\(index)", title: "Session \(index)", updatedAt: Int64(10_000 - index))
      }
    }

    @Test("A long list's first frame builds no row's menu; a menu is built when it opens")
    func firstFrameBuildsNoMenus() throws {
      let spy = SidebarSpy(SidebarViewState(list: SessionListViewState(sessions: sessions(200))))
      var screen: OffscreenWindow<AnyView>?
      let began = ContinuousClock.now
      let renders = RenderTally.recording {
        screen = OffscreenWindow(AnyView(SidebarHarness(spy: spy)), width: 320, height: 800)
      }
      defer { screen?.close() }
      let rows = renders["session row"] ?? 0
      print("first frame of 200 sessions: \(rows) rows built in \(ContinuousClock.now - began)")
      #expect(rows > 0)
      #expect(renders["session row menu"] == nil, "\(renders)")
    }
  }
#endif
