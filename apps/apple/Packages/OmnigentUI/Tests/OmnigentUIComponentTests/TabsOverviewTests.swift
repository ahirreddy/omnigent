#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A window presenting the overview sheet, as the strip's controls do.
  private struct OverviewHost: View {
    let state: TabsState
    let actions: TabActions
    let spy: TabSpy
    @State private var isPresented = true

    var body: some View {
      Color.clear
        .tabOverview(isPresented: $isPresented, state: state, actions: actions)
        .onChange(of: isPresented) { _, shows in if !shows { spy.calls.append("dismissed") } }
    }
  }

  @Suite("Tabs: the overview sheet", .serialized)
  @MainActor
  struct TabsOverviewSheetTests {
    /// The list's first row is its untitled section's.
    static let firstTabRow = 1

    private func sheet(_ state: TabsState, spy: TabSpy, actions: TabActions? = nil)
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(
        AnyView(OverviewHost(state: state, actions: actions ?? spy.actions, spy: spy)),
        width: 600, height: 600)
    }

    /// The sheet's content as a window's root, where context menus can be read.
    private func rootSheet(_ state: TabsState, spy: TabSpy) -> OffscreenWindow<AnyView> {
      let view = TabOverviewSheet(state: state, actions: spy.actions) {}
      return OffscreenWindow(AnyView(view), width: 600, height: 600)
    }

    @Test("It lists each tab with its detail, and marks pinned and selected")
    func rows() throws {
      let screen = sheet(
        TabsState(
          tabs: [TabFixture.tab("one"), TabFixture.tab("two", status: .failed, isPinned: true)],
          selectedID: "one"), spy: TabSpy())
      defer { screen.close() }
      #expect(try screen.shows("One"))
      #expect(try screen.shows("Chat"))
      #expect(try screen.shows("Failed \u{00B7} Chat"))
    }

    @Test("A row selects its tab and closes the sheet")
    func selectRow() throws {
      let spy = TabSpy()
      let screen = sheet(TabFixture.pair, spy: spy)
      defer { screen.close() }
      try screen.clickRow(Self.firstTabRow + 1)
      #expect(spy.calls == ["select two", "dismissed"])
    }

    @Test("A row's context menu is the tab's")
    func contextMenu() throws {
      let spy = TabSpy()
      let screen = rootSheet(TabFixture.pair, spy: spy)
      defer { screen.close() }
      let menu = try #require(try screen.menu(ofRow: Self.firstTabRow))
      try screen.choose("Close Other Tabs", in: menu)
      #expect(spy.calls == ["close others one"])
    }

    @Test("The last tab can't close tabs to its right; others can")
    func closeRightInMenu() throws {
      let screen = rootSheet(TabFixture.pair, spy: TabSpy())
      defer { screen.close() }
      let first = try #require(try screen.menu(ofRow: Self.firstTabRow))
      #expect(first.item(named: "Close Tabs to the Right")?.isEnabled == true)
      let last = try #require(try screen.menu(ofRow: Self.firstTabRow + 1))
      #expect(last.item(named: "Close Tabs to the Right")?.isEnabled == false)
    }

    @Test("With no tabs it says so")
    func empty() throws {
      let screen = sheet(TabsState(), spy: TabSpy())
      defer { screen.close() }
      #expect(try screen.shows("No Tabs"))
    }

    @Test("Ten recently closed tabs are listed at most")
    func recentlyClosed() throws {
      let closed = (0..<12).map { TabFixture.tab("closed\($0)") }
      let screen = sheet(TabsState(tabs: [], recentlyClosed: closed), spy: TabSpy())
      defer { screen.close() }
      #expect(try screen.shows("Recently Closed"))
      #expect(try screen.shows("Closed0"))
      // The two sections, New Tab, ten tabs and Reopen.
      #expect(try #require(screen.list).numberOfRows == 14)
    }

    @Test("Reopen brings a tab back and closes the sheet")
    func reopen() throws {
      let spy = TabSpy()
      let screen = sheet(
        TabsState(
          tabs: [TabFixture.tab("one")], selectedID: "one", recentlyClosed: [TabFixture.tab("gone")]
        ),
        spy: spy)
      defer { screen.close() }
      try screen.clickControl(at: screen.controlFrames.count - 2)
      #expect(spy.calls == ["reopen", "dismissed"])
    }

    @Test("Without a way to reopen, closed tabs aren't listed")
    func noReopen() throws {
      let spy = TabSpy()
      let screen = sheet(
        TabsState(tabs: [TabFixture.tab("one")], recentlyClosed: [TabFixture.tab("closed")]),
        spy: spy, actions: spy.basicActions)
      defer { screen.close() }
      #expect(try !screen.shows("Recently Closed"))
    }

    @Test("Done closes the sheet; New Tab opens a tab and closes it")
    func toolbar() throws {
      let spy = TabSpy()
      let screen = sheet(TabFixture.pair, spy: spy)
      defer { screen.close() }
      let frames = screen.controlFrames
      #expect(!frames.isEmpty)
      // Done is last, under the list.
      try screen.clickControl(at: frames.count - 1)
      #expect(spy.calls == ["dismissed"])
    }

    @Test("New Tab opens a tab and closes the sheet")
    func newTab() throws {
      let spy = TabSpy()
      let screen = sheet(TabFixture.pair, spy: spy)
      defer { screen.close() }
      #expect(try screen.shows("New Tab"))
      // The row after the tabs, above Done.
      try screen.clickControl(at: screen.controlFrames.count - 2)
      #expect(spy.calls == ["new tab", "dismissed"])
    }

    @Test("Searching keeps the tabs whose title or subtitle matches")
    func search() throws {
      var subtitled = TabFixture.tab("two")
      subtitled.subtitle = "main branch"
      let state = TabsState(tabs: [TabFixture.tab("one"), subtitled, TabFixture.tab("three")])
      let screen = sheet(state, spy: TabSpy())
      defer { screen.close() }
      let field = try #require(screen.allViews.compactMap { $0 as? NSSearchField }.first)
      try screen.click(field)
      try screen.type("TWO")
      #expect(try screen.shows("Two"))
      #expect(try !screen.shows("One"))
      #expect(try !screen.shows("Three"))
      for _ in 0..<3 { try screen.press(keyCode: 51, characters: "\u{7F}") }
      try screen.type("BRANCH")
      #expect(try screen.shows("Two"))
      #expect(try !screen.shows("Three"))
    }
  }

  @Suite("Tabs: reordering in the overview")
  struct TabsOverviewMoveTests {
    private let tabs = ["a", "b", "c", "d"].map { TabFixture.tab($0) }

    private func move(_ source: Int, to destination: Int, visible: [String]) -> String? {
      let shown = tabs.filter { visible.contains($0.id) }
      let result = TabOverviewSheet.move(
        from: IndexSet(integer: source), to: destination, visible: shown, in: tabs)
      return result.map { "\($0.id) \($0.index)" }
    }

    @Test("Dragging down the whole list lands before the row it's dropped on")
    func down() {
      #expect(move(0, to: 2, visible: ["a", "b", "c", "d"]) == "a 1")
      #expect(move(0, to: 4, visible: ["a", "b", "c", "d"]) == "a 3")
    }

    @Test("Dragging up lands at the row's place")
    func up() {
      #expect(move(3, to: 0, visible: ["a", "b", "c", "d"]) == "d 0")
    }

    @Test("In a filtered list the move is by the rows shown")
    func filtered() {
      #expect(move(1, to: 0, visible: ["b", "d"]) == "d 1")
      #expect(move(0, to: 2, visible: ["b", "d"]) == "b 3")
    }

    @Test("Dropping a row on itself does nothing; an unknown row does nothing")
    func nothing() {
      #expect(move(1, to: 1, visible: ["a", "b"]) == nil)
      #expect(move(9, to: 0, visible: ["a", "b"]) == nil)
      let empty = TabOverviewSheet.move(from: IndexSet(), to: 0, visible: tabs, in: tabs)
      #expect(empty == nil)
    }

    @Test("A row alone at the end stays at the end of the strip")
    func aloneAtTheEnd() {
      #expect(move(0, to: 1, visible: ["b"]) == "b 3")
    }
  }

  @Suite("Tabs: the tab-count button", .serialized)
  @MainActor
  struct TabsSwitcherTests {
    @Test("Counts up to 50 show in the symbol")
    func symbols() {
      #expect(TabSwitcherButton.symbol(count: 1) == "1.square")
      #expect(TabSwitcherButton.symbol(count: 50) == "50.square")
      #expect(TabSwitcherButton.symbol(count: 0) == "square.on.square")
      #expect(TabSwitcherButton.symbol(count: 51) == "square.on.square")
    }

    @Test("It opens its own sheet")
    func ownSheet() throws {
      let view = TabSwitcherButton(state: TabFixture.pair, actions: TabSpy().actions)
        .frame(width: 400, height: 400)
      let screen = OffscreenWindow(view, width: 400, height: 400)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(screen.window.attachedSheet != nil)
    }

    @Test("A window's presenter takes the click instead")
    func presenter() throws {
      let presenter = TabOverviewPresenter()
      var opened = 0
      presenter.open = { opened += 1 }
      let view = TabSwitcherButton(state: TabFixture.pair, actions: TabSpy().actions)
        .environment(\.tabOverviewPresenter, presenter)
        .frame(width: 400, height: 400)
      let screen = OffscreenWindow(view, width: 400, height: 400)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(opened == 1)
      #expect(screen.window.attachedSheet == nil)
    }
  }
#endif
