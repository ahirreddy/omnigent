#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Tabs: the split divider and small gaps", .serialized)
  @MainActor
  struct TabsGapsSplitTests {
    private let split = TabSplitState(leadingID: "one", trailingID: "two", focused: .leading)

    private func view(_ actions: TabActions) -> OffscreenWindow<AnyView> {
      let content = TabSplitView(split: split, actions: actions) { _ in Color.clear }
        .frame(width: 900, height: 400)
      return OffscreenWindow(AnyView(content), width: 900, height: 400)
    }

    @Test("Dragging the divider sets the panes' shares on release")
    func dragsDivider() throws {
      let spy = TabSpy()
      let screen = view(spy.actions)
      defer { screen.close() }
      try screen.dragGesture(
        from: CGPoint(x: 450, y: 200), through: [CGPoint(x: 460, y: 200), CGPoint(x: 540, y: 200)],
        releases: false)
      #expect(spy.calls.isEmpty, "only the release commits")
      try screen.sendMouse(.leftMouseUp, CGPoint(x: 540, y: 200))
      #expect(spy.calls == ["fraction \(TabSplitLayout.fraction(at: 540, width: 900))"])
    }

    @Test("VoiceOver moves the divider a step either way")
    func adjustsFromVoiceOver() throws {
      let spy = TabSpy()
      let screen = view(spy.actions)
      defer { screen.close() }
      let middle = split.fraction
      try screen.withAccessibilityTree {
        let divider = try screen.accessibilityElement("tab-split-divider")
        #expect(divider.value(forKey: "accessibilityLabel") as? String == "Split divider")
        _ = unsafe divider.perform(NSSelectorFromString("accessibilityPerformIncrement"))
        _ = unsafe divider.perform(NSSelectorFromString("accessibilityPerformDecrement"))
      }
      screen.settle()
      #expect(
        spy.calls == [
          "fraction \(middle + TabSplitLayout.adjustStep)",
          "fraction \(middle - TabSplitLayout.adjustStep)",
        ])
    }

    @Test("A row dragged in the overview list moves the tab in the strip")
    func overviewMove() {
      let spy = TabSpy()
      let sheet = TabOverviewSheet(
        state: TabsState(
          tabs: [TabFixture.tab("one"), TabFixture.tab("two"), TabFixture.tab("three")],
          selectedID: "one"),
        actions: spy.actions, dismiss: {})
      sheet.move(from: IndexSet([2]), to: 0)
      #expect(spy.calls == ["move three 0"])
    }

    @Test("A row that doesn't move moves nothing")
    func overviewStays() {
      let spy = TabSpy()
      let sheet = TabOverviewSheet(state: TabFixture.pair, actions: spy.actions, dismiss: {})
      sheet.move(from: IndexSet(), to: 0)
      sheet.move(from: IndexSet([0]), to: 0)
      #expect(spy.calls.isEmpty)
    }

    @Test("A window's commands start with nothing to do, and no tabs to select")
    func commandDefaults() {
      let actions = TabCommandActions()
      actions.newTab()
      actions.selectTab(3)
      #expect(!actions.supportsSplit)
      #expect(actions.closeTab == nil)
    }

    @Test("The split items show only in a window that can split")
    func splitMenuGroup() {
      var actions = TabCommandActions()
      let cannot = OffscreenWindow(SplitMenuGroup(actions: actions).frame(width: 300, height: 200))
      defer { cannot.close() }
      #expect(cannot.controlFrames.isEmpty)
      actions.supportsSplit = true
      actions.toggleSplit = {}
      actions.focusPane = { _ in }
      let can = OffscreenWindow(
        VStack { SplitMenuGroup(actions: actions) }.frame(width: 300, height: 200))
      defer { can.close() }
      #expect(can.controlFrames.count == 3)
    }

    @Test("The selected tab is the one the state names, if it's there")
    func selectedTab() {
      #expect(TabFixture.pair.selected?.id == "one")
      #expect(TabsState(tabs: [TabFixture.tab("a")], selectedID: "gone").selected == nil)
    }
  }
#endif
