#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

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

    @Test("A tab only its own window can show has no Move Tab to New Window")
    func boundToItsWindow() throws {
      var tab = TabFixture.tab("one")
      tab.canMoveToNewWindow = false
      let (screen, menu) = try menu(tab, spy: TabSpy())
      defer { screen.close() }
      let items = try #require(menu)
      #expect(items.item(named: "Move Tab to New Window") == nil)
      #expect(items.item(named: "Close Tab") != nil)
    }
  }

  @Suite("Tabs: a titlebar tab's context menu", .serialized)
  @MainActor
  struct TabsTitlebarMenuTests {
    private func secondaryClick(in view: NSView, at point: NSPoint) throws -> NSEvent {
      let window = try #require(unsafe view.window)
      let event = NSEvent.mouseEvent(
        with: .rightMouseDown, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
      return try #require(event)
    }

    @Test("A secondary click on the tab is taken and shows the tab's own menu")
    func takesTheToolbarsClick() async throws {
      let spy = TabSpy()
      let view = TabItemView(
        tab: TabFixture.tab("one"), isSelected: true, width: 224, actions: spy.actions,
        canCloseToRight: true, isInTitlebar: true
      )
      .frame(width: 300, height: 40)
      let screen = OffscreenWindow(AnyView(view), width: 300, height: 40)
      defer { screen.close() }
      let clicks = try #require(
        screen.allViews.compactMap { $0 as? TitlebarMenuClickView }.first)
      var shown: [NSMenu] = []
      clicks.present = { menu, _, _ in shown.append(menu) }
      #expect(clicks.hitTest(NSPoint(x: clicks.bounds.midX, y: clicks.bounds.midY)) == nil)

      let outside = NSPoint(x: clicks.bounds.maxX + 2_000, y: clicks.bounds.maxY + 2_000)
      let takenOutside = clicks.takes(try secondaryClick(in: clicks, at: outside))
      #expect(!takenOutside, "bounds \(clicks.bounds), visible \(clicks.visibleRect)")

      let inside = NSPoint(x: clicks.bounds.midX, y: clicks.bounds.midY)
      #expect(clicks.takes(try secondaryClick(in: clicks, at: inside)))
      // The menu opens after the click's monitor returns.
      for _ in 0..<100 where shown.isEmpty {
        try await Task.sleep(for: .milliseconds(20))
      }
      let menu = try #require(shown.first)
      try screen.choose("Open in Split View", in: menu)
      #expect(spy.calls == ["show one trailing"])
    }

    /// A press through the application, where the titlebar tab's event monitor listens.
    private func pressThroughApp(
      _ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], in view: NSView
    ) throws {
      let window = try #require(unsafe view.window)
      let middle = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
      let event = NSEvent.mouseEvent(
        with: type, location: view.convert(middle, to: nil), modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
      NSApp.sendEvent(try #require(event))
    }

    @Test(
      "A Control-click and a right click on a titlebar tab open its menu; a plain click selects")
    func clicksThroughTheApp() async throws {
      let spy = TabSpy()
      let view = TabItemView(
        tab: TabFixture.tab("one"), isSelected: false, width: 224, actions: spy.actions,
        canCloseToRight: true, isInTitlebar: true
      )
      .frame(width: 300, height: 40)
      let screen = OffscreenWindow(AnyView(view), width: 300, height: 40)
      defer { screen.close() }
      let clicks = try #require(
        screen.allViews.compactMap { $0 as? TitlebarMenuClickView }.first)
      var shown: [NSMenu] = []
      clicks.present = { menu, _, _ in shown.append(menu) }
      // A window that isn't key takes a press as first mouse, and no tap follows.
      screen.window.makeKey()

      try pressThroughApp(.leftMouseDown, in: clicks)
      try pressThroughApp(.leftMouseUp, in: clicks)
      try await screen.letTasksRun()
      #expect(spy.calls == ["select one"])
      #expect(shown.isEmpty, "a plain click is the tab's, not the menu's")

      try pressThroughApp(.leftMouseDown, modifiers: .control, in: clicks)
      for _ in 0..<100 where shown.isEmpty { try await screen.letTasksRun() }
      try pressThroughApp(.rightMouseDown, in: clicks)
      for _ in 0..<100 where shown.count < 2 { try await screen.letTasksRun() }
      #expect(shown.count == 2)
      #expect(spy.calls == ["select one"], "the menu's clicks never reach the tab")
      try screen.choose("Close Tab", in: try #require(shown.last))
      #expect(spy.calls == ["select one", "close one"])
    }

    @Test("A tab outside the titlebar leaves the click to SwiftUI's menu")
    func onlyInTheTitlebar() {
      let view = TabItemView(
        tab: TabFixture.tab("one"), isSelected: true, width: 224, actions: TabSpy().actions,
        canCloseToRight: true
      )
      .frame(width: 300, height: 40)
      let screen = OffscreenWindow(AnyView(view), width: 300, height: 40)
      defer { screen.close() }
      #expect(!screen.allViews.contains { $0 is TitlebarMenuClickView })
    }

    @Test("Right clicks and Control-clicks inside open the menu; plain clicks do not")
    func menuClicks() {
      typealias Clicks = TitlebarMenuClickView
      #expect(Clicks.isMenuClick(isRightButton: true, modifiers: [], isInside: true))
      #expect(Clicks.isMenuClick(isRightButton: false, modifiers: .control, isInside: true))
      #expect(!Clicks.isMenuClick(isRightButton: false, modifiers: [], isInside: true))
      #expect(!Clicks.isMenuClick(isRightButton: false, modifiers: .command, isInside: true))
      #expect(!Clicks.isMenuClick(isRightButton: true, modifiers: [], isInside: false))
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

    @Test("VoiceOver hears when an agent drives a browser tab, and when the user took over")
    func agentControl() {
      var tab = TabFixture.tab("page", .browser)
      tab.agentControl = .active
      #expect(
        TabItemView.accessibilityValue(tab, isVisibleInOtherPane: false)
          == "Browser, Agent is controlling this tab")
      tab.agentControl = .user
      #expect(
        TabItemView.accessibilityValue(tab, isVisibleInOtherPane: false)
          == "Browser, You're in control")
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
