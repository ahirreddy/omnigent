#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// What drawing a long sidebar costs: its first frame builds the rows it shows, once each,
  /// and no row's menu.
  @Suite("Sidebar: the cost of its rows", .serialized)
  @MainActor
  struct SidebarRowCostTests {
    private func sessions(_ count: Int) -> [SessionSummary] {
      (0..<count).map { index in
        SessionSummary(
          id: "s\(index)", title: "Session \(index)", updatedAt: Int64(10_000 - index))
      }
    }

    @Test("A long list's first frame builds the rows on screen, and no row's menu")
    func firstFrameBuildsTheRowsOnScreen() throws {
      let spy = SidebarSpy(SidebarViewState(list: SessionListViewState(sessions: sessions(200))))
      var screen: OffscreenWindow<AnyView>?
      let renders = RenderTally.recording {
        screen = OffscreenWindow(AnyView(SidebarHarness(spy: spy)), width: 320, height: 800)
      }
      defer { screen?.close() }
      let rows = renders["session row"] ?? 0
      // About a window's worth: the list counts a row without building it while its type says
      // it is one row.
      #expect(rows > 0)
      #expect(rows < 60, "\(renders)")
      #expect(renders["session row menu"] == nil, "\(renders)")
    }

    @Test("A nested row and a folder's rows still count as one row each")
    func familyAndFolderRowsStayLazy() throws {
      var state = SidebarProjectsFixture.state
      state.list.sessions += sessions(150)
      let spy = SidebarSpy(state)
      UserDefaults.standard.set(
        SidebarProjectsFixture.expanded.joined(separator: "\n"),
        forKey: SidebarNavigationOrder.expandedProjectsKey)
      var screen: OffscreenWindow<AnyView>?
      let renders = RenderTally.recording {
        screen = OffscreenWindow(AnyView(SidebarHarness(spy: spy)), width: 320, height: 800)
      }
      defer { screen?.close() }
      #expect((renders["session row"] ?? 0) < 60, "\(renders)")
    }
  }
#endif
