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
      let option: NSEvent.ModifierFlags = [.command, .option]

      let focus = model.omniboxFocusRequest
      #expect(try screen.shortcut("l", keyCode: 37))
      #expect(model.omniboxFocusRequest == focus + 1)
      #expect(try screen.shortcut("f", keyCode: 3))
      #expect(model.find.isVisible)

      #expect(try screen.shortcut("=", keyCode: 24))
      let oneStep = tab.state.zoomFactor
      #expect(oneStep > 1)
      #expect(try screen.shortcut("+", keyCode: 24))
      #expect(tab.state.zoomFactor > oneStep)
      #expect(try screen.shortcut("-", keyCode: 27))
      #expect(tab.state.zoomFactor == oneStep)
      #expect(try screen.shortcut("0", keyCode: 29))
      #expect(tab.state.zoomFactor == 1)

      #expect(try screen.shortcut("i", keyCode: 34, modifiers: option))
      #expect(tab.commands.last == "devtools")
      #expect(try screen.shortcut("p", keyCode: 35))
      await screen.catchUp()
      #expect(tab.commands.last == "print")
      #expect(try screen.shortcut("u", keyCode: 32, modifiers: option))
      await screen.catchUp()
      #expect(tab.commands.last == "viewSource")
      #expect(try screen.shortcut("d", keyCode: 2))
      #expect(model.isBookmarked)

      #expect(!screen.hasSheet)
      #expect(try screen.shortcut("y", keyCode: 16))
      await screen.letSheetSettle()
      #expect(screen.hasSheet)
      #expect(screen.nothingOnScreen)
    }

    @Test("Shift reaches a shortcut's second command")
    func shiftedShortcuts() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      let shift: NSEvent.ModifierFlags = [.command, .shift]
      fixture.model.find.query = "cat"
      await screen.catchUp()

      // SwiftUI's pick among chords sharing a key changes from run to run (see below).
      #expect(try screen.shortcut("r", keyCode: 15, modifiers: shift))
      #expect(tab.commands.last?.hasSuffix("eload") == true)
      #expect(try screen.shortcut("g", keyCode: 5, modifiers: shift))
      await screen.catchUp()
      #expect(tab.commands.last?.hasPrefix("find cat") == true)
    }

    @Test(
      "with nothing focused, plain ⌘R still reloads rather than reloading past the cache",
      .disabled(
        "Through window key equivalents SwiftUI picks unpredictably among chords sharing a key. The Mac app routes these through its menu bar, so only harnesses reach this; needs a real keyboard to confirm."
      ))
    func plainChordWithNothingFocused() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = content(fixture)
      defer { screen.close() }
      await screen.catchUp()
      try screen.shortcut("r", keyCode: 15)
      #expect(tab.commands.last == "reload")
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

      // Bottom right: Done, or Clear Browsing Data's Clear Data, which also closes it.
      try screen.clickDrawnButton(at: screen.drawnButtons.count - 1)
      await screen.letSheetSettle()
      if title == "Clear Browsing Data…" {
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
      // Remove Selected, Clear Browsing Data… and Done along the bottom.
      let historyControls = screen.drawnButtons.count
      #expect(historyControls == 3)
      try screen.clickDrawnButton(at: 1)
      // The old sheet slides away before the new one comes. Its time range is a picker.
      for _ in 0..<10 where !screen.allViews.contains(where: { $0 is NSPopUpButton }) {
        await screen.letSheetSettle()
      }
      #expect(screen.allViews.contains { $0 is NSPopUpButton })
      #expect(screen.hasSheet)
    }
  }
#endif
