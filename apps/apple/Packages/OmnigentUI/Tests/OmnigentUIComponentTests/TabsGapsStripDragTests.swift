#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Dragging a tab with the mouse: the strip's gesture, its reorder calls and where a release lands.
  /// Mouse events go to the offscreen window; `DragGesture` starts no system drag.
  @Suite("Tabs: dragging on the strip", .serialized)
  @MainActor
  struct TabsGapsStripDragTests {
    private static let width: CGFloat = 900
    private static let height: CGFloat = 300

    /// A strip above a content area, as the shell lays them out, sharing the tracker.
    private func screen(
      _ state: TabsState, _ actions: TabActions, tracker: TabDragTracker? = nil
    ) -> OffscreenWindow<AnyView> {
      let tracker = tracker ?? TabDragTracker()
      let view = VStack(spacing: 0) {
        TabStrip(state: state, actions: actions)
        TabSplitView(split: state.split, actions: actions) { _ in Color.clear }
      }
      .environment(tracker)
      .frame(width: Self.width, height: Self.height)
      return OffscreenWindow(AnyView(view), width: Self.width, height: Self.height)
    }

    private static let stripY: CGFloat = 19

    private func tab(_ index: Int) -> CGPoint {
      CGPoint(x: 4 + 224 * (CGFloat(index) + 0.5), y: Self.stripY)
    }

    private var three: TabsState {
      TabsState(
        tabs: [TabFixture.tab("one"), TabFixture.tab("two"), TabFixture.tab("three")],
        selectedID: "one")
    }

    @Test("Dragging a tab past its neighbour moves it there, and the release keeps it")
    func reorders() throws {
      let spy = TabSpy()
      let screen = screen(three, spy.actions)
      defer { screen.close() }
      let start = tab(0)
      try screen.dragGesture(
        from: start,
        through: [
          CGPoint(x: start.x + 10, y: start.y), CGPoint(x: start.x + 240, y: start.y),
        ])
      #expect(spy.calls.contains("move one 1"))
      #expect(!spy.calls.contains { $0.hasPrefix("new window") || $0.hasPrefix("show") })
    }

    @Test("Released well below the strip in the content's middle, the tab moves to a new window")
    func tearsOff() throws {
      let spy = TabSpy()
      let screen = screen(three, spy.actions)
      defer { screen.close() }
      let start = tab(1)
      try screen.dragGesture(
        from: start,
        through: [
          CGPoint(x: start.x, y: start.y + 10), CGPoint(x: 450, y: start.y + 150),
        ])
      #expect(spy.calls == ["new window two"])
    }

    @Test("A release on a content edge shows the tab in that pane; the tracker ends")
    func dropsOnEdge() throws {
      let spy = TabSpy()
      let tracker = TabDragTracker()
      let screen = screen(three, spy.actions, tracker: tracker)
      defer { screen.close() }
      let start = tab(1)
      try screen.dragGesture(
        from: start,
        through: [CGPoint(x: start.x, y: start.y + 10), CGPoint(x: 850, y: start.y + 150)],
        releases: false)
      #expect(tracker.draggedID == "two")
      #expect(tracker.target == .trailing)
      try screen.sendMouse(.leftMouseUp, CGPoint(x: 850, y: start.y + 150))
      #expect(spy.calls == ["show two trailing"])
      #expect(tracker.draggedID == nil)
    }

    @Test("Without a pane or a new window to go to, a release leaves the tab")
    func staysWithoutDrops() throws {
      let spy = TabSpy()
      let screen = screen(three, spy.basicActions)
      defer { screen.close() }
      let start = tab(1)
      try screen.dragGesture(
        from: start,
        through: [CGPoint(x: start.x, y: start.y + 10), CGPoint(x: 850, y: start.y + 150)])
      #expect(spy.calls.isEmpty)
    }

    @Test("In a split window, a release on the other pane's section moves the tab to that pane")
    func movesToOtherSection() throws {
      let spy = TabSpy()
      let state = TabsState(
        tabs: [
          TabFixture.tab("one", pane: .leading), TabFixture.tab("two", pane: .trailing),
        ],
        selectedID: "one",
        split: TabSplitState(leadingID: "one", trailingID: "two", focused: .leading))
      let screen = screen(state, spy.actions)
      defer { screen.close() }
      try screen.dragGesture(
        from: CGPoint(x: 60, y: Self.stripY),
        through: [CGPoint(x: 70, y: Self.stripY), CGPoint(x: 600, y: Self.stripY)])
      #expect(spy.calls.contains("show one trailing"))
    }

    @Test("In a split window a tab swaps only with the tabs of its own pane")
    func swapsInsideItsPane() throws {
      let spy = TabSpy()
      let state = TabsState(
        tabs: [
          TabFixture.tab("one", pane: .leading), TabFixture.tab("two", pane: .leading),
          TabFixture.tab("three", pane: .trailing),
        ],
        selectedID: "one",
        split: TabSplitState(leadingID: "one", trailingID: "three", focused: .leading))
      let screen = screen(state, spy.actions)
      defer { screen.close() }
      try screen.dragGesture(
        from: CGPoint(x: 60, y: 19), through: [CGPoint(x: 70, y: 19), CGPoint(x: 300, y: 19)])
      #expect(spy.calls.contains("move one 1"))
    }
  }

  @Suite("Tabs: the strip in the titlebar", .serialized)
  @MainActor
  struct TabsGapsTitlebarTests {
    @Test("A double-click on the titlebar's empty space follows the system setting, not New Tab")
    func doubleClickFollowsTheSetting() throws {
      // "None" keeps the offscreen window where it is; TabsEdgeTests checks each setting's effect.
      let defaults = UserDefaults.standard
      defaults.set("None", forKey: "AppleActionOnDoubleClick")
      defer { defaults.removeObject(forKey: "AppleActionOnDoubleClick") }
      let spy = TabSpy()
      let strip = TabStrip(state: TabFixture.pair, actions: spy.actions, isInTitlebar: true)
        .frame(width: 700, height: 38)
      let screen = OffscreenWindow(strip, width: 700, height: 38)
      defer { screen.close() }
      let frame = screen.window.frame
      let empty = CGPoint(x: 560, y: 19)
      try screen.click(empty, clickCount: 1)
      try screen.click(empty, clickCount: 2)
      #expect(spy.calls.isEmpty)
      #expect(screen.window.frame == frame)
    }
  }
#endif
