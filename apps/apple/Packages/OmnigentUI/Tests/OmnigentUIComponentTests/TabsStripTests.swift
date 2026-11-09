#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Tabs: the strip's buttons", .serialized)
  @MainActor
  struct TabsStripTests {
    private func strip(_ state: TabsState, _ actions: TabActions, width: CGFloat = 700) -> some View
    {
      TabStrip(state: state, actions: actions).frame(width: width, height: 38)
    }

    @Test("New Tab opens a tab")
    func newTab() throws {
      let spy = TabSpy()
      let screen = OffscreenWindow(strip(TabFixture.pair, spy.actions), width: 700, height: 38)
      defer { screen.close() }
      // The selected tab's Close, New Tab, the overview menu.
      #expect(screen.controlFrames.count == 3)
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["new tab"])
    }

    @Test("The selected tab always has a Close button")
    func closeSelected() throws {
      let spy = TabSpy()
      let screen = OffscreenWindow(strip(TabFixture.pair, spy.actions), width: 700, height: 38)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["close one"])
    }

    @Test("A tab that can't close has no Close button, selected or hovered")
    func notClosable() throws {
      let spy = TabSpy()
      let state = TabsState(
        tabs: [TabFixture.tab("one", isClosable: false), TabFixture.tab("two", isClosable: false)],
        selectedID: "one")
      let screen = OffscreenWindow(strip(state, spy.actions), width: 700, height: 38)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 2)
      try screen.hover(screen.tabCenter(index: 1, width: 224))
      #expect(screen.controlFrames.count == 2)
    }

    @Test("A background tab shows Close only while hovered, and closes that tab")
    func hoverClose() throws {
      let spy = TabSpy()
      let screen = OffscreenWindow(strip(TabFixture.pair, spy.actions), width: 700, height: 38)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 3)
      try screen.hover(screen.tabCenter(index: 1, width: 224))
      // Close on both tabs now, then New Tab and the menu.
      #expect(screen.controlFrames.count == 4)
      try screen.clickControl(at: 1)
      #expect(spy.calls == ["close two"])
    }

    @Test("Hovering a background tab swaps its status mark for Close")
    func hoverReplacesStatus() throws {
      let spy = TabSpy()
      var running = TabFixture.tab("two", status: .needsYou)
      running.isPlayingAudio = true
      let state = TabsState(tabs: [TabFixture.tab("one"), running], selectedID: "one")
      let screen = OffscreenWindow(strip(state, spy.actions), width: 700, height: 38)
      defer { screen.close() }
      #expect(screen.controlFrames.count == 3)
      try screen.hover(screen.tabCenter(index: 1, width: 224))
      #expect(screen.controlFrames.count == 4)
    }

    @Test("Each tab's title shows; an untitled tab shows its kind")
    func titles() throws {
      let untitled = TabItemState(id: "x", kind: .terminal, title: "")
      let state = TabsState(tabs: [TabFixture.tab("one"), untitled], selectedID: "one")
      let screen = OffscreenWindow(strip(state, TabSpy().actions), width: 700, height: 38)
      defer { screen.close() }
      #expect(try screen.shows("One"))
      #expect(try screen.shows("Terminal"))
    }

    @Test("A pinned tab shows no title and has no Close button")
    func pinned() throws {
      let state = TabsState(
        tabs: [TabFixture.tab("pinned", isPinned: true), TabFixture.tab("one")],
        selectedID: "pinned")
      let screen = OffscreenWindow(strip(state, TabSpy().actions), width: 700, height: 38)
      defer { screen.close() }
      #expect(try !screen.shows("Pinned"))
      #expect(try screen.shows("One"))
      // New Tab and the overview menu only: the selected tab is the pinned one.
      #expect(screen.controlFrames.count == 2)
    }

    @Test("A split strip lists each pane's tabs, and only the focused pane's has Close")
    func splitSections() throws {
      let split = TabSplitState(leadingID: "one", trailingID: "two", focused: .trailing)
      let state = TabsState(
        tabs: [TabFixture.tab("one", pane: .leading), TabFixture.tab("two", pane: .trailing)],
        selectedID: "two", split: split)
      let spy = TabSpy()
      let screen = OffscreenWindow(strip(state, spy.actions, width: 800), width: 800, height: 38)
      defer { screen.close() }
      #expect(try screen.shows("One"))
      #expect(try screen.shows("Two"))
      #expect(screen.controlFrames.count == 3)
      try screen.clickControl(at: 0)
      #expect(spy.calls == ["close two"])
    }

    @Test("Inside the titlebar the strip leaves its controls to the host")
    func withoutControls() throws {
      let view = TabStrip(
        state: TabFixture.pair, actions: TabSpy().actions, isInTitlebar: true,
        includesControls: false
      )
      .frame(width: 700, height: 30)
      let screen = OffscreenWindow(view, width: 700, height: 30)
      defer { screen.close() }
      // Only the selected tab's Close.
      #expect(screen.controlFrames.count == 1)
    }

    @Test("Many tabs scroll: the far ones are not squeezed to nothing")
    func overflow() throws {
      let tabs = (0..<12).map { TabFixture.tab("tab\($0)") }
      let state = TabsState(tabs: tabs, selectedID: "tab11")
      let screen = OffscreenWindow(
        strip(state, TabSpy().actions, width: 500), width: 500, height: 38)
      defer { screen.close() }
      // The selected tab scrolled into view, and its Close sits inside the window.
      let close = try #require(screen.controlFrames.first)
      #expect(close.minX > 0)
      #expect(close.maxX < 500)
      #expect(try screen.shows("Tab11"))
    }

    @Test("Every status draws something different from a plain tab")
    func statuses() throws {
      func picture(_ status: TabStatus, audio: Bool = false, isSelected: Bool) throws -> Data {
        var tab = TabFixture.tab("two", status: status)
        tab.isPlayingAudio = audio
        let state = TabsState(
          tabs: [TabFixture.tab("one"), tab], selectedID: isSelected ? "two" : "one")
        return try RenderSupport.picture(
          TabStrip(state: state, actions: TabActions()), width: 600, height: 38)
      }
      for isSelected in [true, false] {
        let plain = try picture(.none, isSelected: isSelected)
        for status in [
          TabStatus.needsYou, .failed, .running, .loading, .terminalActivity, .unread, .exited,
        ] {
          let marked = try picture(status, isSelected: isSelected)
          #expect(marked != plain, "\(status) selected \(isSelected)")
        }
        #expect(try picture(.none, audio: true, isSelected: isSelected) != plain)
      }
    }

    @Test("A pinned tab's dot follows its status, and a finished one has none")
    func pinnedDots() throws {
      func picture(_ status: TabStatus) throws -> Data {
        let state = TabsState(
          tabs: [TabFixture.tab("pinned", status: status, isPinned: true)], selectedID: nil)
        return try RenderSupport.picture(
          TabStrip(state: state, actions: TabActions()), width: 400, height: 38)
      }
      let plain = try picture(.none)
      #expect(try picture(.exited) == plain)
      let dots: [TabStatus] = [.needsYou, .unread, .failed, .running, .loading, .terminalActivity]
      for status in dots {
        #expect(try picture(status) != plain, "\(status)")
      }
    }

    @Test("A tab's favicon and profile dot replace and mark its icon")
    func iconParts() throws {
      func picture(_ edit: (inout TabItemState) -> Void) throws -> Data {
        var tab = TabFixture.tab("one", .browser)
        edit(&tab)
        return try RenderSupport.picture(
          TabStrip(state: TabsState(tabs: [tab]), actions: TabActions()), width: 400, height: 38)
      }
      let plain = try picture { _ in }
      let favicon = try #require(faviconData())
      #expect(try picture { $0.favicon = favicon } != plain)
      #expect(try picture { $0.favicon = Data("not an image".utf8) } == plain)
      #expect(try picture { $0.profileColor = .red } != plain)
    }

    private func faviconData() -> Data? {
      let image = NSImage(size: CGSize(width: 16, height: 16), flipped: false) { rect in
        NSColor.systemRed.setFill()
        rect.fill()
        return true
      }
      return image.tiffRepresentation
    }

    @Test("The overflow fade only covers an end with tabs out of view")
    func overflowFade() throws {
      func picture(leading: Bool, trailing: Bool) throws -> Data {
        try RenderSupport.picture(
          TabOverflowFade(overflow: TabOverflow(leading: leading, trailing: trailing)), width: 200,
          height: 20)
      }
      let none = try picture(leading: false, trailing: false)
      #expect(try picture(leading: true, trailing: false) != none)
      #expect(try picture(leading: false, trailing: true) != none)
    }

    @Test("The issue's warning shows beside the controls")
    func issue() throws {
      func picture(_ issue: String?) throws -> Data {
        try RenderSupport.picture(
          TabStripControls(state: TabsState(issue: issue), actions: TabActions()), width: 200,
          height: 38)
      }
      #expect(try picture("Could not restore tabs") != picture(nil))
    }
  }
#endif
