#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  @MainActor
  @Suite("Tab toolbar, off screen", .serialized)
  struct TabToolbarViewTests {
    private func toolbar(_ fixture: TabFixture) -> some View {
      BrowserTabToolbar(
        model: fixture.model, environment: fixture.environment, sheet: .constant(nil))
    }

    @Test("back and forward follow the page's history and reach the tab")
    func backAndForward() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(toolbar(fixture), width: 900, height: 60)
      defer { screen.close() }
      #expect(screen.buttons.count >= 3)
      #expect(!screen.buttons[0].isEnabled)
      #expect(!screen.buttons[1].isEnabled)
      tab.state.canGoBack = true
      tab.state.canGoForward = true
      screen.settle()
      #expect(screen.buttons[0].isEnabled)
      #expect(screen.buttons[1].isEnabled)
      try screen.clickButton(at: 0)
      try screen.clickButton(at: 1)
      #expect(tab.commands == ["back", "forward"])
    }

    @Test("the reload button stops a load, and reloads otherwise")
    func reloadAndStop() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(toolbar(fixture), width: 900, height: 60)
      defer { screen.close() }
      try screen.clickButton(at: 2)
      #expect(tab.commands == ["reload"])
      tab.state.isLoading = true
      screen.settle()
      try screen.clickButton(at: 2)
      #expect(tab.commands == ["reload", "stop"])
      #expect(screen.nothingOnScreen)
    }

    @Test("the mute button shows only for audio, and toggles the tab")
    func mute() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(toolbar(fixture), width: 900, height: 60)
      defer { screen.close() }
      let quiet = screen.buttons.count
      tab.state.isAudible = true
      screen.settle()
      #expect(screen.buttons.count == quiet + 1)
      // Back, forward, reload, the bookmark star and then mute.
      try screen.clickButton(at: 4)
      #expect(tab.state.isMuted)
      #expect(fixture.model.isMuted)
      tab.state.isAudible = false
      screen.settle()
      #expect(screen.buttons.count == quiet + 1)
      try screen.clickButton(at: 4)
      #expect(!tab.state.isMuted)
      #expect(screen.buttons.count == quiet)
    }

    @Test("the zoom badge shows away from 100%, and resets it")
    func zoomBadge() throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let screen = OffscreenWindow(toolbar(fixture), width: 900, height: 60)
      defer { screen.close() }
      let plain = screen.buttons.count
      fixture.model.zoomIn()
      screen.settle()
      #expect(screen.buttons.count == plain + 1)
      #expect(tab.state.zoomFactor > 1)
      try screen.clickButton(at: 4)
      #expect(tab.state.zoomFactor == 1)
      #expect(screen.buttons.count == plain)
    }

    @Test("a page that can't be bookmarked has no star")
    func starFollowsThePage() throws {
      let fixture = try TabFixture(url: "about:blank")
      let screen = OffscreenWindow(toolbar(fixture), width: 900, height: 60)
      defer { screen.close() }
      let blank = screen.buttons.count
      fixture.model.load(try testURL("https://b.example/"))
      screen.settle()
      #expect(screen.buttons.count == blank + 1)
      try screen.clickButton(at: 3)
      #expect(fixture.model.isBookmarked)
      try screen.clickButton(at: 3)
      #expect(!fixture.model.isBookmarked)
    }

    @Test("the overflow menu runs its commands and opens its sheets")
    func overflowMenu() async throws {
      let fixture = try TabFixture()
      let tab = try fixture.tab
      let sheet = SheetRecorder()
      let screen = OffscreenWindow(
        BrowserTabMenu(
          model: fixture.model, environment: fixture.environment,
          sheet: Binding(get: { sheet.value }, set: { sheet.value = $0 })), width: 200, height: 60)
      defer { screen.close() }
      let menu = try screen.popupMenu()
      let expected: [(String, BrowserTabSheet)] = [
        ("History", .history), ("Bookmarks", .bookmarks), ("Downloads", .downloads),
        ("Site Permissions…", .siteSettings), ("Clear Browsing Data…", .clearData),
        ("Profiles…", .profiles),
      ]
      for (title, target) in expected {
        try screen.choose(title, in: menu)
        #expect(sheet.value == target, "\(title)")
      }
      try screen.choose("Bookmark This Page", in: menu)
      #expect(fixture.model.isBookmarked)
      try screen.choose("Find…", in: menu)
      #expect(fixture.model.find.isVisible)
      try screen.choose("Zoom In", in: menu)
      #expect(tab.state.zoomFactor > 1)
      try screen.choose("Zoom Out", in: menu)
      #expect(tab.state.zoomFactor == 1)
      try screen.choose("Zoom In", in: menu)
      try screen.choose("Actual Size", in: menu)
      #expect(tab.state.zoomFactor == 1)
      try screen.choose("Mute Tab", in: menu)
      #expect(tab.state.isMuted)
      try screen.choose("Reload Ignoring Cache", in: menu)
      try screen.choose("Print…", in: menu)
      try screen.choose("View Source", in: menu)
      try screen.choose("Developer Tools", in: menu)
      await screen.catchUp()
      #expect(Set(tab.commands) == ["hardReload", "devtools", "print", "viewSource"])
    }

    @Test("the engine submenu lists what this build offers, and switches")
    func engineMenu() throws {
      let fixture = try TabFixture()
      let screen = OffscreenWindow(
        BrowserTabMenu(
          model: fixture.model, environment: fixture.environment, sheet: .constant(nil)),
        width: 200, height: 60)
      defer { screen.close() }
      let menu = try screen.popupMenu()
      let engines = fixture.model.controller.offeredEngines
      #expect(engines == BrowserEngineKind.allCases)
      try screen.choose(BrowserEngineKind.chromium.displayName, in: menu)
      #expect(fixture.model.engineKind == .chromium)
      #expect(fixture.environment.preferences.engine == .chromium)
    }
  }

  /// Holds what a sheet binding was set to.
  @MainActor
  final class SheetRecorder {
    var value: BrowserTabSheet?
  }
#endif
