#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// The trailing items a detail reports, changed from the test, and how often the shell built
  /// its detail.
  @MainActor
  @Observable
  private final class ReportedItems {
    var count: Int?
    @ObservationIgnored var detailBuilds = 0
  }

  /// Reports the trailing items the test set, without the shell's harness rendering for it.
  private struct ReportsTrailingItems: ViewModifier {
    let fixed: Int?
    let items: ReportedItems?

    func body(content: Content) -> some View {
      content.preference(key: TitlebarTrailingItems.self, value: items.map(\.count) ?? fixed)
    }
  }

  private struct ShellHarness: View {
    let spy: SidebarSpy
    var tabs: (state: TabsState, actions: TabActions)?
    var toggle: SidebarToggle?
    var sizeClass: UserInterfaceSizeClass?
    var trailingItems: Int?
    var items: ReportedItems?

    var body: some View {
      AppShell(
        sidebar: spy.state, selection: Binding(get: { spy.selection }, set: { spy.selection = $0 }),
        searchText: Binding(get: { spy.search }, set: { spy.search = $0 }), actions: spy.actions,
        tabs: tabs, detail: detail
      )
      .environment(\.sidebarToggle, toggle)
      .environment(\.horizontalSizeClass, sizeClass)
    }

    private func detail(_ destination: SidebarDestination?) -> some View {
      items?.detailBuilds += 1
      return Text("detail of \(destination.map { "\($0)" } ?? "nothing")")
        .modifier(ReportsTrailingItems(fixed: trailingItems, items: items))
    }
  }

  @Suite("Adaptive: the window's shell", .serialized)
  @MainActor
  struct AdaptiveShellTests {
    private func shell(_ harness: ShellHarness, width: CGFloat = 1_100) -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(AnyView(harness), width: width, height: 700)
    }

    private func item(_ screen: OffscreenWindow<AnyView>) -> [NSSplitViewItem] {
      let split = screen.allViews.lazy.compactMap { $0 as? NSSplitView }.first
      return (split?.delegate as? NSSplitViewController)?.splitViewItems ?? []
    }

    @Test("The sidebar and the selected destination's detail show side by side")
    func twoColumns() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      spy.selection = .session("beta")
      let screen = shell(ShellHarness(spy: spy))
      defer { screen.close() }
      #expect(try screen.shows("Beta"))
      #expect(try screen.shows("detail of session(\"beta\")"))
      #expect(item(screen).first?.isCollapsed == false)
    }

    @Test("The window's toggle hides the sidebar, and shows it again")
    func toggleHidesSidebar() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let toggle = SidebarToggle()
      let screen = shell(ShellHarness(spy: spy, toggle: toggle))
      defer { screen.close() }
      toggle()
      screen.settle(0.3)
      #expect(item(screen).first?.isCollapsed == true)
      toggle()
      screen.settle(0.3)
      #expect(item(screen).first?.isCollapsed == false)
    }

    @Test("Content fills its own column: nothing draws under the sidebar")
    func detailBesideSidebar() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = shell(ShellHarness(spy: spy))
      defer { screen.close() }
      let detail = try #require(item(screen).last)
      #expect(!detail.automaticallyAdjustsSafeAreaInsets)
      // Its marker view in the column takes no clicks.
      let marker = try #require(
        screen.allViews.first {
          String(reflecting: Swift.type(of: $0)).contains("DetailBesideSidebar")
        })
      #expect(marker.hitTest(.zero) == nil)
    }

    @Test("A toggle with no shell does nothing, and toggling flips between shown and hidden")
    func toggleAlone() {
      SidebarToggle()()
      #expect(SidebarToggle.toggled(.detailOnly) == .all)
      #expect(SidebarToggle.toggled(.all) == .detailOnly)
      #expect(SidebarToggle.toggled(.doubleColumn) == .detailOnly)
    }

    /// A window with a titlebar, so the shell's toolbar has somewhere to go.
    private func titled(_ harness: ShellHarness, width: CGFloat = 1_100) -> OffscreenWindow<AnyView>
    {
      let screen = shell(harness, width: width)
      screen.window.contentView = nil
      screen.window.styleMask = [.titled, .resizable, .fullSizeContentView]
      screen.host.sceneBridgingOptions = [.toolbars, .title]
      screen.window.contentView = screen.host
      screen.settle(0.5)
      return screen
    }

    private func tabs() -> (state: TabsState, actions: TabActions) {
      (TabsState(tabs: [TabFixture.tab("a")], selectedID: "a"), TabSpy().actions)
    }

    private func toolbarItems(_ screen: OffscreenWindow<AnyView>) -> [NSToolbarItem] {
      screen.window.toolbar?.items ?? []
    }

    @Test("With tabs, the strip and its New Tab controls sit in the titlebar")
    func tabsInTitlebar() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = titled(ShellHarness(spy: spy, tabs: tabs(), trailingItems: 2))
      defer { screen.close() }
      let items = toolbarItems(screen)
      // The strip, a flexible space and the controls.
      #expect(items.count == 3)
      #expect(items.compactMap(\.view).count == 2)
      #expect(try screen.shows("detail of nothing"))
    }

    @Test("The strip takes the detail's width less what the screen says sits beside it")
    func stripWidth() throws {
      func stripWidth(trailingItems: Int?, windowWidth: CGFloat = 1_100) throws -> CGFloat {
        let spy = SidebarSpy(SidebarFixture.state)
        let screen = titled(
          ShellHarness(spy: spy, tabs: tabs(), trailingItems: trailingItems), width: windowWidth)
        defer { screen.close() }
        let view = try #require(toolbarItems(screen).first?.view)
        return try #require(view.subviews.first).frame.width
      }
      // A screen that doesn't report its items gets room for all of them.
      let reported = try stripWidth(trailingItems: 2)
      let reserved = try stripWidth(trailingItems: nil)
      #expect(
        reported - reserved == TitlebarMetrics.trailingReserve
          - TitlebarMetrics.trailingWidth(items: 2)
      )
      // In a tight window it stops shrinking, and the toolbar folds trailing items instead.
      let tight = try stripWidth(trailingItems: nil, windowWidth: 600)
      let tighter = try stripWidth(trailingItems: nil, windowWidth: 560)
      #expect(tight == tighter)
    }

    @Test("A tab with other trailing items resizes the strip without rendering the shell again")
    func trailingItemsResizeOnlyTheStrip() throws {
      let items = ReportedItems()
      items.count = 2
      let screen = titled(
        ShellHarness(spy: SidebarSpy(SidebarFixture.state), tabs: tabs(), items: items))
      defer { screen.close() }
      // The detail column is measured again, at the window's new width.
      screen.window.setContentSize(CGSize(width: 1_200, height: 700))
      screen.settle(0.5)
      let strip = try #require(toolbarItems(screen).first?.view)
      let reported = strip.fittingSize.width
      let builds = items.detailBuilds

      // What switching from a conversation to a terminal or a web page does.
      items.count = nil
      screen.settle(0.5)

      let itemsWidth = TitlebarMetrics.trailingWidth(items: 2)
      #expect(reported - strip.fittingSize.width == TitlebarMetrics.trailingReserve - itemsWidth)
      #expect(items.detailBuilds == builds, "the shell, sidebar and detail did not render again")
    }

    @Test("A compact window puts a Tabs button in the bar instead of the strip")
    func compactTabs() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = titled(ShellHarness(spy: spy, tabs: tabs(), sizeClass: .compact), width: 500)
      defer { screen.close() }
      #expect(toolbarItems(screen).count == 1)
      #expect(try screen.shows("detail of nothing"))
    }

    @Test("Without tabs the bar is empty")
    func noTabs() {
      let spy = SidebarSpy(SidebarFixture.state)
      let screen = titled(ShellHarness(spy: spy))
      defer { screen.close() }
      #expect(toolbarItems(screen).compactMap(\.view).isEmpty)
    }

    @Test("A collapsed sidebar peeks when the pointer rests on the window's edge")
    func peeksWhenCollapsed() async throws {
      let spy = SidebarSpy(SidebarFixture.state)
      let toggle = SidebarToggle()
      let screen = shell(ShellHarness(spy: spy, toggle: toggle))
      defer { screen.close() }
      toggle()
      screen.settle(0.3)
      let tracker = try #require(
        screen.allViews.first { String(describing: Swift.type(of: $0)).contains("TrackingView") })
      let edge = try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: CGPoint(x: 2, y: 100), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
      tracker.mouseMoved(with: edge)
      try await Task.sleep(for: SidebarPeek.revealDelay + .milliseconds(30))
      screen.settle(0.3)
      let peekMarker = screen.allViews.contains {
        $0.frame.width == SidebarPeekOverlay<EmptyView>.panelWidth
      }
      #expect(peekMarker)
    }

    @Test("Launch arguments choose how the sidebar starts")
    func launchState() throws {
      let defaults = try #require(UserDefaults(suiteName: "adaptive-launch-state"))
      defer { defaults.removePersistentDomain(forName: "adaptive-launch-state") }
      #expect(SidebarLaunchState.read(defaults) == nil)
      defaults.set("peek", forKey: SidebarLaunchState.defaultsKey)
      #expect(SidebarLaunchState.read(defaults) == .peek)
      defaults.set("collapsed", forKey: SidebarLaunchState.defaultsKey)
      #expect(SidebarLaunchState.read(defaults) == .collapsed)
      defaults.set("other", forKey: SidebarLaunchState.defaultsKey)
      #expect(SidebarLaunchState.read(defaults) == nil)
    }

    @Test("The strip leaves room for what's around it, and never gets too small")
    func titlebarRoom() {
      #expect(TitlebarMetrics.trailingWidth(items: 0) == 32)
      #expect(TitlebarMetrics.trailingWidth(items: 3) == 140)
      // The traffic lights and the sidebar toggle need room once the sidebar is hidden.
      let beside = TitlebarMetrics.stripWidth(
        detailWidth: 900, isSidebarHidden: false, trailingItems: 1)
      let hidden = TitlebarMetrics.stripWidth(
        detailWidth: 900, isSidebarHidden: true, trailingItems: 1)
      #expect(beside == 900 - 68 - TitlebarMetrics.newTabControls)
      #expect(beside - hidden == TitlebarMetrics.collapsedLeading)
      #expect(
        TitlebarMetrics.stripWidth(detailWidth: 100, isSidebarHidden: true, trailingItems: nil)
          == TitlebarMetrics.minimumStrip)
      #expect(
        TitlebarMetrics.stripWidth(detailWidth: 900.5, isSidebarHidden: false, trailingItems: nil)
          == 600)

      var reported: Int?
      TitlebarTrailingItems.reduce(value: &reported) { 2 }
      #expect(reported == 2)
      // A view that says nothing keeps what an earlier one reported.
      TitlebarTrailingItems.reduce(value: &reported) { nil }
      #expect(reported == 2)
    }
  }
#endif
