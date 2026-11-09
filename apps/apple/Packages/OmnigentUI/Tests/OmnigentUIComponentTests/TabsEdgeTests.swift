#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Records what a titlebar double click asks of the window, without moving a real one.
  @MainActor
  private final class RecordingWindow: NSWindow {
    var requests: [String] = []
    override func performZoom(_ sender: Any?) { requests.append("zoom") }
    override func performMiniaturize(_ sender: Any?) { requests.append("minimize") }
  }

  @Suite("Tabs: smaller paths", .serialized)
  @MainActor
  struct TabsEdgeTests {
    @Test("A titlebar double click follows the user's Desktop & Dock setting")
    func titlebarDoubleClick() {
      func request(_ setting: String?) -> [String] {
        let window = RecordingWindow(
          contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        TitlebarDoubleClick.perform(on: window, setting: setting)
        return window.requests
      }
      #expect(request(nil) == ["zoom"])
      #expect(request("Maximize") == ["zoom"])
      #expect(request("Minimize") == ["minimize"])
      #expect(request("None").isEmpty)
      // No window to act on is no error.
      TitlebarDoubleClick.perform(on: nil, setting: "Minimize")
    }

    @Test("In the titlebar, a double click on the empty strip takes the setting, not a new tab")
    func doubleClickInTitlebar() throws {
      let key = "AppleActionOnDoubleClick"
      UserDefaults.standard.set("None", forKey: key)
      defer { UserDefaults.standard.removeObject(forKey: key) }
      let spy = TabSpy()
      let strip = TabStrip(
        state: TabFixture.pair, actions: spy.actions, isInTitlebar: true, includesControls: false)
      let screen = OffscreenWindow(AnyView(strip), width: 700, height: 38)
      defer { screen.close() }
      let empty = CGPoint(x: 600, y: 19)
      try screen.click(empty, clickCount: 1)
      try screen.click(empty, clickCount: 2)
      #expect(spy.calls.isEmpty)
    }

    @Test("VoiceOver moves the divider in even steps")
    func dividerAdjust() {
      #expect(TabSplitLayout.adjusted(0.5, direction: .increment) == 0.55)
      #expect(TabSplitLayout.adjusted(0.5, direction: .decrement) == 0.45)
    }

    @Test("Pinned and unpinned tabs are told apart, in order")
    func pinnedLists() {
      let state = TabsState(
        tabs: [
          TabFixture.tab("one"), TabFixture.tab("two", isPinned: true), TabFixture.tab("three"),
        ], selectedID: "one")
      #expect(state.pinned.map(\.id) == ["two"])
      #expect(state.unpinned.map(\.id) == ["one", "three"])
    }

    @Test("Actions left at their defaults do nothing, and hide what they'd offer")
    func defaultActions() {
      let actions = TabActions()
      actions.select("a")
      actions.close("a")
      actions.newTab()
      actions.move("a", 0)
      actions.setPinned("a", true)
      actions.duplicate("a")
      actions.closeOthers("a")
      actions.closeToRight("a")
      #expect(actions.reopenClosed == nil)
      #expect(actions.moveToNewWindow == nil)

      let newTab = NewTabPageActions()
      newTab.newSession()
      newTab.openSession("s")
      #expect(newTab.newTerminal == nil)
      #expect(newTab.openBrowser == nil)
    }

    @Test("A tab outside a split isn't offered pane items, by default")
    func defaultMenu() throws {
      let spy = TabSpy()
      let tab = TabFixture.tab("one")
      let menu = TabContextMenu(tab: tab, actions: spy.actions, canCloseToRight: true)
      let screen = OffscreenWindow(AnyView(Menu("Tab") { menu }), width: 300, height: 60)
      defer { screen.close() }
      let items = try screen.openMenu(control: 0)
      #expect(!items.titles.isEmpty)
      #expect(!items.titles.contains { $0.localizedCaseInsensitiveContains("pane") })

      let view = TabItemView(
        tab: tab, isSelected: false, width: 180, actions: spy.actions, canCloseToRight: true)
      let row = OffscreenWindow(AnyView(view), width: 200, height: 38)
      defer { row.close() }
      let rowMenu = try #require(try row.contextMenu(at: CGPoint(x: 90, y: 19)))
      #expect(rowMenu.titles.contains("Close Tab"))
    }
  }
#endif
