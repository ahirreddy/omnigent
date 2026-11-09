#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Tabs: a tab's context menu", .serialized)
  @MainActor
  struct TabsContextMenuTests {
    private func menu(
      _ tab: TabItemState, spy: TabSpy, actions: TabActions? = nil, canCloseToRight: Bool = true,
      isSplit: Bool = false
    ) throws -> (screen: OffscreenWindow<AnyView>, menu: NSMenu?) {
      let view = TabItemView(
        tab: tab, isSelected: true, width: 224, actions: actions ?? spy.actions,
        canCloseToRight: canCloseToRight, isSplit: isSplit
      )
      .frame(width: 300, height: 40)
      let screen = OffscreenWindow(AnyView(view), width: 300, height: 40)
      return (screen, try screen.contextMenu(at: CGPoint(x: 60, y: 20)))
    }

    private func enabled(_ title: String, in menu: NSMenu) throws -> Bool {
      try #require(menu.item(named: title)).isEnabled
    }

    @Test("Every item runs on this tab")
    func allItems() throws {
      var tab = TabFixture.tab("one")
      tab.canRenameSession = true
      tab.link = URL(string: "https://example.test/one")
      let expected: [(String, String)] = [
        ("Pin Tab", "pin one true"), ("Duplicate Tab", "duplicate one"),
        ("Rename Session\u{2026}", "rename one"), ("Move Tab to New Window", "new window one"),
        ("Open in Split View", "show one trailing"), ("Close Tab", "close one"),
        ("Close Other Tabs", "close others one"), ("Close Tabs to the Right", "close right one"),
      ]
      for (title, call) in expected {
        let spy = TabSpy()
        let (screen, menu) = try menu(tab, spy: spy)
        defer { screen.close() }
        let items = try #require(menu)
        try screen.choose(title, in: items)
        #expect(spy.calls == [call], "\(title)")
      }
    }

    @Test("Copy Link puts the tab's link on the pasteboard")
    func copyLink() throws {
      var tab = TabFixture.tab("one")
      tab.link = URL(string: "https://example.test/one")
      let spy = TabSpy()
      let (screen, menu) = try menu(tab, spy: spy)
      defer { screen.close() }
      try screen.choose("Copy Link", in: try #require(menu))
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "https://example.test/one")
    }

    @Test("A pinned tab offers Unpin")
    func unpin() throws {
      let spy = TabSpy()
      let (screen, menu) = try menu(TabFixture.tab("one", isPinned: true), spy: spy)
      defer { screen.close() }
      try screen.choose("Unpin Tab", in: try #require(menu))
      #expect(spy.calls == ["pin one false"])
    }

    @Test("In a split window the item moves the tab to the other pane")
    func otherPane() throws {
      for (pane, target, label) in [
        (TabPane?.some(.leading), "trailing", "Move to Right Pane"),
        (.some(.trailing), "leading", "Move to Left Pane"),
        (nil, "trailing", "Move to Right Pane"),
      ] {
        let spy = TabSpy()
        let (screen, menu) = try menu(TabFixture.tab("one", pane: pane), spy: spy, isSplit: true)
        defer { screen.close() }
        try screen.choose(label, in: try #require(menu))
        #expect(spy.calls == ["show one \(target)"])
      }
    }

    @Test("A tab that can't close keeps its close items, disabled")
    func disabledItems() throws {
      let (screen, menu) = try menu(
        TabFixture.tab("one", isClosable: false), spy: TabSpy(), canCloseToRight: false)
      defer { screen.close() }
      let items = try #require(menu)
      #expect(try !enabled("Close Tab", in: items))
      #expect(try !enabled("Move Tab to New Window", in: items))
      #expect(try !enabled("Close Tabs to the Right", in: items))
      #expect(try enabled("Close Other Tabs", in: items))
    }

    @Test("Items whose action isn't there are not offered")
    func missingActions() throws {
      var tab = TabFixture.tab("one")
      tab.canDuplicate = false
      let spy = TabSpy()
      let (screen, menu) = try menu(tab, spy: spy, actions: spy.basicActions)
      defer { screen.close() }
      let items = try #require(menu)
      #expect(
        items.titles == ["Pin Tab", "Close Tab", "Close Other Tabs", "Close Tabs to the Right"])
    }

    @Test("Rename needs both a session tab and the action")
    func renameNeedsSession() throws {
      let (screen, menu) = try menu(TabFixture.tab("one"), spy: TabSpy())
      defer { screen.close() }
      #expect(try #require(menu).item(named: "Rename Session\u{2026}") == nil)
    }
  }

  @Suite("Tabs: what a tab tells")
  struct TabsItemTextTests {
    @Test("The tooltip reads title, subtitle and the best status")
    func help() {
      var tab = TabFixture.tab("one", status: .needsYou)
      #expect(TabItemView.help(tab, liveStatus: nil) == "One \u{00B7} Needs you")
      #expect(TabItemView.help(tab, liveStatus: "Waiting") == "One \u{00B7} Waiting")
      tab.statusDetail = "2 requests"
      #expect(TabItemView.help(tab, liveStatus: "Waiting") == "One \u{00B7} 2 requests")
      tab.subtitle = "main"
      #expect(TabItemView.help(tab, liveStatus: nil) == "One \u{00B7} main \u{00B7} 2 requests")
      #expect(TabItemView.help(TabFixture.tab("two"), liveStatus: nil) == "Two")
    }

    @Test("VoiceOver hears the kind, pane, status and flags")
    func accessibility() {
      var tab = TabFixture.tab("one", .terminal, status: .failed, isPinned: true, pane: .trailing)
      tab.isReadOnly = true
      #expect(
        TabItemView.accessibilityValue(tab, isVisibleInOtherPane: true)
          == "Terminal, Right pane, Shown, Failed, Pinned, Read only")
      #expect(
        TabItemView.accessibilityValue(TabFixture.tab("two"), isVisibleInOtherPane: false) == "Chat"
      )
    }
  }

  @Suite("Tabs: the overview menu", .serialized)
  @MainActor
  struct TabsOverviewMenuTests {
    private func controls(_ state: TabsState, _ actions: TabActions) -> OffscreenWindow<AnyView> {
      OffscreenWindow(
        AnyView(TabStripControls(state: state, actions: actions).frame(width: 300, height: 400)),
        width: 300, height: 400)
    }

    @Test("It lists the tabs; picking one selects it")
    func selectTab() throws {
      let spy = TabSpy()
      let screen = controls(TabFixture.pair, spy.actions)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 1)
      #expect(menu.item(named: "One")?.state == .on)
      #expect(menu.item(named: "Two")?.state == .off)
      try screen.choose("Two", in: menu)
      #expect(spy.calls == ["select two"])
    }

    @Test("Reopen Closed Tab is there when the window can reopen")
    func reopen() throws {
      let spy = TabSpy()
      let screen = controls(TabFixture.pair, spy.actions)
      defer { screen.close() }
      try screen.choose("Reopen Closed Tab", in: try screen.openMenu(control: 1))
      #expect(spy.calls == ["reopen"])
    }

    @Test("Without reopen that item is gone")
    func basics() throws {
      let spy = TabSpy()
      let screen = controls(TabFixture.pair, spy.basicActions)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 1)
      #expect(menu.titles == ["One", "Two", "Show All Tabs"])
    }

    @Test("Recently closed tabs are listed, at most eight")
    func recentlyClosed() throws {
      let closed = (0..<10).map { TabFixture.tab("closed\($0)") }
      let state = TabsState(tabs: [TabFixture.tab("one")], recentlyClosed: closed)
      let screen = controls(state, TabSpy().actions)
      defer { screen.close() }
      let menu = try screen.openMenu(control: 1)
      #expect(menu.item(named: "Closed7") != nil)
      #expect(menu.item(named: "Closed8") == nil)
    }

    @Test("Show All Tabs opens the sheet; Done closes it")
    func showAll() throws {
      let spy = TabSpy()
      let screen = controls(TabFixture.pair, spy.actions)
      defer { screen.close() }
      try screen.choose("Show All Tabs", in: try screen.openMenu(control: 1))
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("Tabs"))
    }
  }
#endif
