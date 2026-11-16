#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// The Chat / Terminal switch a session's chat tab carries in the strip.
  @Suite("Tabs: the chat tab's Chat / Terminal switch", .serialized)
  @MainActor
  struct TabViewModeSwitchTests {
    /// A session's chat tab, which cannot close, showing `mode`.
    private func chat(_ mode: SessionViewMode?, isPinned: Bool = false) -> TabItemState {
      var tab = TabFixture.tab("chat", isPinned: isPinned, isClosable: false)
      tab.viewMode = mode
      return tab
    }

    private func strip(_ state: TabsState, _ actions: TabActions) -> OffscreenWindow<some View> {
      OffscreenWindow(
        TabStrip(state: state, actions: actions).frame(width: 700, height: 38), width: 700,
        height: 38)
    }

    @Test("Each side shows that view of the chat, and the click neither selects nor closes a tab")
    func sidesChoose() throws {
      let spy = TabSpy()
      let state = TabsState(tabs: [chat(.chat), TabFixture.tab("two")], selectedID: "two")
      let screen = strip(state, spy.actions)
      defer { screen.close() }
      // The switch's two sides lead the chat's tab; then Close on the selected tab, New Tab
      // and the overview menu.
      let controls = screen.controlFrames
      try #require(controls.count == 5, "\(controls)")
      #expect(controls[1].minX - controls[0].maxX < 4, "the two sides sit together")
      #expect(controls[1].maxX < 80, "at the tab's leading end, in place of its icon")

      try screen.clickControl(at: 1)
      #expect(spy.calls == ["view chat terminal"])
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["view chat terminal", "view chat chat"], "the shown side answers too")

      // The rest of the tab is still the tab: a click on its title selects it.
      try screen.click(CGPoint(x: controls[1].maxX + 60, y: 19))
      #expect(spy.calls.last == "select chat")
    }

    @Test("The shown view's side is the lit one")
    func shownSideIsLit() throws {
      func picture(_ mode: SessionViewMode) throws -> Data {
        try RenderSupport.picture(TabViewModeSwitch(mode: mode) { _ in }, width: 60, height: 24)
      }
      let chat = try picture(.chat)
      #expect(chat != (try picture(.terminal)))
      #expect(chat == (try picture(.chat)), "the same view draws the same")
    }

    @Test(
      "A tab with no terminal view, a pinned chat tab and a window without the action keep the icon"
    )
    func noSwitch() throws {
      let spy = TabSpy()
      let plain = strip(TabsState(tabs: [chat(nil)], selectedID: "chat"), spy.actions)
      defer { plain.close() }
      #expect(plain.controlFrames.count == 2, "New Tab and the overview menu")

      let pinned = strip(
        TabsState(tabs: [chat(.chat, isPinned: true)], selectedID: "chat"), spy.actions)
      defer { pinned.close() }
      #expect(pinned.controlFrames.count == 2)

      let noAction = strip(TabsState(tabs: [chat(.chat)], selectedID: "chat"), spy.basicActions)
      defer { noAction.close() }
      #expect(noAction.controlFrames.count == 2)
    }

    @Test("The tab's menu shows the other view, pinned or not")
    func menuItem() throws {
      for (mode, title, call) in [
        (SessionViewMode.chat, "Show Terminal", "view chat terminal"),
        (.terminal, "Show Chat", "view chat chat"),
      ] {
        let spy = TabSpy()
        let view = TabItemView(
          tab: chat(mode, isPinned: mode == .terminal), isSelected: true, width: 224,
          actions: spy.actions, canCloseToRight: false
        )
        .frame(width: 300, height: 40)
        let screen = OffscreenWindow(AnyView(view), width: 300, height: 40)
        defer { screen.close() }
        let menu = try #require(try screen.contextMenu(at: CGPoint(x: 150, y: 20)))
        try screen.choose(title, in: menu)
        #expect(spy.calls == [call], "\(title)")
      }
      let spy = TabSpy()
      let view = TabItemView(
        tab: chat(nil), isSelected: true, width: 224, actions: spy.actions, canCloseToRight: false
      )
      .frame(width: 300, height: 40)
      let screen = OffscreenWindow(AnyView(view), width: 300, height: 40)
      defer { screen.close() }
      let menu = try #require(try screen.contextMenu(at: CGPoint(x: 150, y: 20)))
      #expect(menu.item(named: "Show Terminal") == nil && menu.item(named: "Show Chat") == nil)
    }
  }
#endif
