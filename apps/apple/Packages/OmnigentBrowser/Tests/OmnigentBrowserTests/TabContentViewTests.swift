#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  @MainActor
  @Suite("Tab content, off screen", .serialized)
  struct TabContentViewTests {
    private func content(_ fixture: TabFixture, keyboardShortcuts: Bool = true)
      -> OffscreenWindow<BrowserTabContentView>
    {
      OffscreenWindow(
        BrowserTabContentView(
          model: fixture.model, environment: fixture.environment,
          keyboardShortcuts: keyboardShortcuts),
        width: 900, height: 600)
    }

    @Test("every keyboard shortcut does what its menu item says")
    func shortcuts() async throws {
      let fixture = try TabFixture()
      fixture.environment.onOpenTab = { _, _ in }
      let tab = try fixture.tab
      let model = fixture.model
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let shift: NSEvent.ModifierFlags = [.command, .shift]
      let option: NSEvent.ModifierFlags = [.command, .option]

      let focus = model.omniboxFocusRequest
      try screen.press(keyCode: 37, characters: "l", modifiers: .command)
      #expect(model.omniboxFocusRequest == focus + 1)

      try screen.press(keyCode: 3, characters: "f", modifiers: .command)
      #expect(model.find.isVisible)
      model.find.query = "cat"
      await screen.catchUp()
      try screen.press(keyCode: 5, characters: "g", modifiers: shift)
      await screen.catchUp()
      #expect(tab.commands.last == "find cat backward false")
      try screen.press(keyCode: 5, characters: "g", modifiers: .command)
      await screen.catchUp()
      #expect(tab.commands.last == "find cat forward false")

      try screen.press(keyCode: 24, characters: "=", modifiers: .command)
      let oneStep = tab.state.zoomFactor
      #expect(oneStep > 1)
      try screen.press(keyCode: 24, characters: "+", modifiers: .command)
      #expect(tab.state.zoomFactor > oneStep)
      try screen.press(keyCode: 27, characters: "-", modifiers: .command)
      #expect(tab.state.zoomFactor == oneStep)
      try screen.press(keyCode: 29, characters: "0", modifiers: .command)
      #expect(tab.state.zoomFactor == 1)

      try screen.press(keyCode: 15, characters: "r", modifiers: .command)
      #expect(tab.commands.last == "reload")
      try screen.press(keyCode: 15, characters: "r", modifiers: shift)
      #expect(tab.commands.last == "hardReload")
      try screen.press(keyCode: 34, characters: "i", modifiers: option)
      #expect(tab.commands.last == "devtools")
      try screen.press(keyCode: 35, characters: "p", modifiers: .command)
      await screen.catchUp()
      #expect(tab.commands.last == "print")
      try screen.press(keyCode: 32, characters: "u", modifiers: option)
      await screen.catchUp()
      #expect(tab.commands.last == "viewSource")
      try screen.press(keyCode: 2, characters: "d", modifiers: .command)
      #expect(model.isBookmarked)

      #expect(!screen.hasSheet)
      try screen.press(keyCode: 16, characters: "y", modifiers: .command)
      await screen.letSheetSettle()
      #expect(screen.hasSheet)
      #expect(screen.nothingOnScreen)
    }

    @Test("with the app's menu providing them, the view leaves the shortcuts alone")
    func shortcutsCanBeOff() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = content(fixture, keyboardShortcuts: false)
      defer { screen.close() }
      await screen.catchUp()
      try screen.press(keyCode: 2, characters: "d", modifiers: .command)
      try screen.press(keyCode: 3, characters: "f", modifiers: .command)
      try screen.press(keyCode: 15, characters: "r", modifiers: .command)
      #expect(!fixture.model.isBookmarked)
      #expect(!fixture.model.find.isVisible)
      #expect(tab.commands.isEmpty)
    }

    @Test("the find bar appears and goes with the model")
    func findBarFollowsTheModel() async throws {
      let fixture = try TabFixture()
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let fieldsWithout = screen.fields.count
      fixture.model.showFindBar()
      await screen.catchUp()
      #expect(screen.fields.count == fieldsWithout + 1)
      fixture.model.hideFindBar()
      await screen.catchUp()
      #expect(screen.fields.count == fieldsWithout)
    }

    @Test("the load progress shows only while loading")
    func progress() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      tab.state.isLoading = true
      tab.state.estimatedProgress = 0.5
      await screen.catchUp()
      #expect(screen.progressBars.map(\.doubleValue).contains { abs($0 - 0.5) < 0.01 })
      tab.state.estimatedProgress = 0
      await screen.catchUp()
      #expect(screen.progressBars.map(\.doubleValue).contains { abs($0 - 0.05) < 0.01 })
      tab.state.isLoading = false
      await screen.catchUp()
      #expect(screen.progressBars.allSatisfy { $0.doubleValue == 0 })
    }

    @Test("a tab error shows, and the banner's button dismisses it")
    func errorBanner() async throws {
      let fixture = try TabFixture()
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let without = screen.buttons.count
      fixture.model.lastError = .tabNotReady
      await screen.catchUp()
      #expect(screen.buttons.count == without + 1)
      try screen.clickButton(at: screen.buttons.count - 1)
      #expect(fixture.model.lastError == nil)
      await screen.catchUp()
      #expect(screen.buttons.count == without)
    }

    @Test("switching the engine in settings moves an open tab over")
    func engineSwitchReachesAnOpenTab() async throws {
      let fixture = try TabFixture(engine: .system)
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      #expect(fixture.model.controller.activeEngine == .system)
      fixture.environment.preferences.engine = .chromium
      await screen.catchUp()
      #expect(fixture.model.controller.activeEngine == .chromium)
    }

    @Test(
      "the menu's sheets each open, and Done or Cancel closes them",
      arguments: [
        "History", "Bookmarks", "Downloads", "Site Permissions…", "Clear Browsing Data…",
        "Profiles…",
      ])
    func sheets(title: String) async throws {
      let fixture = try TabFixture()
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()

      try screen.choose(title, in: screen.popupMenu())
      await screen.letSheetSettle()
      #expect(screen.hasSheet, "\(title)")
      #expect(screen.nothingOnScreen)

      try screen.press(keyCode: 36, characters: "\r")
      await screen.letSheetSettle()
      if title == "Clear Browsing Data…" {
        // Return is its default action, Clear Data; that also closes the sheet.
        #expect(fixture.provider.engines[.system]?.removed.count == 1)
      }
      #expect(!screen.hasSheet, "\(title)")
    }

    @Test("History's clear button swaps its sheet for Clear Browsing Data")
    func historySendsYouToClearData() async throws {
      let fixture = try TabFixture()
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      try screen.choose("History", in: screen.popupMenu())
      await screen.letSheetSettle()
      let first = try #require(screen.window.attachedSheet)
      // Remove Selected, Clear Browsing Data…, Done, in that order.
      #expect(screen.controlFrames.count >= 3)
      let frames = screen.controlFrames.sorted { $0.minX < $1.minX }
      let clear = frames[frames.count - 2]
      try screen.click(CGPoint(x: clear.midX, y: clear.midY))
      await screen.letSheetSettle()
      #expect(screen.window.attachedSheet !== first)
      #expect(screen.hasSheet)
    }
  }
#endif
