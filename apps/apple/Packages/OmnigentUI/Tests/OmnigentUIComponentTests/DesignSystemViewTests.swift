#if os(macOS)
  import AppKit
  import OmnigentPlatform
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// A transient banner with the state a window keeps it in.
  private struct BannerHost: View {
    let banner: EditedValue<TransientBanner?>
    let action: (@MainActor (TransientBanner) -> Void)?

    var body: some View {
      Color.clear.transientBanner(banner.binding, action: action)
    }
  }

  private struct CopyHost: View {
    @Environment(\.copyWithConfirmation) private var copy

    var body: some View {
      VStack {
        Button("Copy") { copy("the text", confirmation: "Link copied") }
        Menu("More") {
          ConfirmedCopyButton(
            title: "Copy path", systemImage: "doc", text: "/tmp/a", confirmation: "Path copied")
        }
      }
    }
  }

  @Suite("Design system views, clicked", .serialized)
  @MainActor
  struct DesignSystemViewTests {
    private let log = ActionLog()

    @Test("a banner shows its message and action; the action runs once and hides it")
    func bannerAction() throws {
      SystemSideEffects.reset()
      let banner = EditedValue<TransientBanner?>(
        TransientBanner(message: "Reply sent", actionTitle: "Open"))
      let log = log
      let screen = OffscreenWindow(
        BannerHost(banner: banner) { log.record("run \($0.message)") }, width: 400, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("Reply sent"))
      #expect(try screen.shows("Open"))
      try screen.clickControl(at: 0)
      #expect(log.entries == ["run Reply sent"])
      #expect(banner.value == nil)
    }

    @Test("a banner with no handler offers no action")
    func bannerWithoutAction() throws {
      SystemSideEffects.reset()
      let banner = EditedValue<TransientBanner?>(
        TransientBanner(message: "Done", actionTitle: "Open"))
      let screen = OffscreenWindow(BannerHost(banner: banner, action: nil), width: 400, height: 200)
      defer { screen.close() }
      #expect(try screen.shows("Done"))
      #expect(try !screen.shows("Open"))
    }

    @Test("repeats of a message are different banners, so each restarts the timer")
    func bannerIdentity() {
      let first = TransientBanner(message: "Copied")
      let second = TransientBanner(message: "Copied")
      #expect(first != second)
    }

    @Test("a copy reaches the pasteboard and confirms when the window can show it")
    func copyConfirms() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(CopyHost().copyConfirmations(), width: 400, height: 200)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "the text")
      #expect(try screen.shows("Link copied"))
    }

    @Test("a menu's copy item does the same")
    func copyFromMenu() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(CopyHost().copyConfirmations(), width: 400, height: 200)
      defer { screen.close() }
      let more = try #require(screen.controlFrames.last)
      let menu = try screen.openMenu(CGPoint(x: more.midX, y: more.midY))
      try screen.choose("Copy path", in: menu)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "/tmp/a")
      #expect(try screen.shows("Path copied"))
    }

    @Test("outside a confirming window a copy only copies")
    func copyAlone() throws {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(CopyHost(), width: 400, height: 200)
      defer { screen.close() }
      try screen.clickControl(at: 0)
      #expect(SystemSideEffects.pasteboard.string(forType: .string) == "the text")
      #expect(try !screen.shows("Link copied"))
    }

    @Test("two windows' copy actions differ, so a view updates when moved between them")
    func copyActionEquality() {
      let presenter = CopyConfirmationPresenter()
      let action = CopyAction(presenter: presenter)
      let sameWindow = CopyAction(presenter: presenter)
      #expect(action == sameWindow)
      #expect(action != CopyAction(presenter: CopyConfirmationPresenter()))
    }

    @Test("a bounded scroll view is as tall as short content, and caps at its limit")
    func boundedScroll() throws {
      SystemSideEffects.reset()
      let short = OffscreenWindow(
        BoundedScrollView(maxHeight: 100) { Color.red.frame(height: 30) }, width: 200, height: 300)
      defer { short.close() }
      short.settle(0.05)
      let shortScroll = try #require(short.allViews.compactMap { $0 as? NSScrollView }.first)
      #expect(shortScroll.frame.height == 30)
      let tall = OffscreenWindow(
        BoundedScrollView(maxHeight: 100) { Color.red.frame(height: 500) }, width: 200, height: 300)
      defer { tall.close() }
      tall.settle(0.05)
      let tallScroll = try #require(tall.allViews.compactMap { $0 as? NSScrollView }.first)
      #expect(tallScroll.frame.height == 100)
    }
  }

  @Suite("Appearance settings, clicked", .serialized)
  @MainActor
  struct DesignSystemThemeSettingsTests {
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "theme-settings-\(UUID())"))
    }

    private func screen(_ preferences: ThemePreferences) -> OffscreenWindow<some View> {
      settingsForm(store: store, height: 1_600) { ThemeSettingsView(preferences: preferences) }
    }

    @Test("Mode and terminal theme write their keys")
    func modeAndTerminal() throws {
      let preferences = ThemePreferences(defaults: store)
      let screen = screen(preferences)
      defer { screen.close() }
      let mode = try #require(screen.segmentedControls.first)
      try screen.click(segment: 2, of: mode)
      #expect(preferences.mode == AppearancePreference.allCases[2])
      #expect(store.string(forKey: ThemePreferences.modeKey) == preferences.mode.rawValue)
      let terminal = try #require(
        screen.popUps.first { $0.title == TerminalThemePreference.auto.title })
      try screen.choose(TerminalThemePreference.dark.title, inPopUp: terminal)
      #expect(preferences.terminal == .dark)
    }

    @Test("picking a color makes the theme Custom with that color")
    func pickColor() throws {
      let preferences = ThemePreferences(defaults: store)
      let screen = screen(preferences)
      defer { screen.close() }
      let well = try #require(screen.allViews.lazy.compactMap { $0 as? NSColorWell }.first)
      well.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
      _ = well.sendAction(well.action, to: well.target)
      screen.settle()
      #expect(preferences.paletteID == "custom")
    }

    @Test("a palette says what it is; Custom says what it's based on")
    func palette() throws {
      let preferences = ThemePreferences(defaults: store)
      let screen = screen(preferences)
      defer { screen.close() }
      #expect(try screen.shows(preferences.theme.blurb))
      preferences.paletteID = "custom"
      screen.settle()
      #expect(
        try screen.shows("Based on \(OmnigentTheme.named(preferences.custom.basePalette).name)"))
    }

    @Test("turning on translucent sidebars makes the current preset Custom, based on it")
    func translucentBecomesCustom() throws {
      let preferences = ThemePreferences(defaults: store)
      let base = try #require(OmnigentTheme.builtIn.last)
      preferences.paletteID = base.id
      let screen = screen(preferences)
      defer { screen.close() }
      try screen.click(try #require(screen.switches.last))
      #expect(preferences.paletteID == "custom")
      #expect(preferences.custom.translucentSidebar)
      #expect(preferences.custom.basePalette == base.id)
      #expect(preferences.custom.accent == ThemeSettingsView.hex(base.light.accent))
    }

    @Test("the contrast slider edits and reads back a whole number")
    func contrast() throws {
      var custom = CustomTheme.default
      custom.contrast = 42.4
      let preferences = ThemePreferences(defaults: store)
      preferences.custom = custom
      let screen = screen(preferences)
      defer { screen.close() }
      #expect(try screen.shows("42"))
      let slider = try #require(screen.allViews.compactMap { $0 as? NSSlider }.first)
      let frame = slider.convert(slider.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.maxX - 2, y: frame.midY))
      #expect(preferences.paletteID == "custom")
      #expect(preferences.custom.contrast > 90)
    }

    @Test("a contrast from a hand-edited settings file can't crash Settings")
    func hugeContrast() throws {
      store.set(
        ##"{"accent":"#000000","basePalette":"omni","contrast":1e300,"darkAccent":"#000000","##
          + ##""darkTint":"#000000","tint":"#ffffff","translucentSidebar":false}"##,
        forKey: ThemePreferences.customKey)
      let preferences = ThemePreferences(defaults: store)
      #expect(preferences.custom.contrast == 1e300)
      let screen = screen(preferences)
      defer { screen.close() }
      #expect(try screen.shows("100"))
    }

    @Test("what couldn't be read says so under the section")
    func readErrors() throws {
      store.set("not a mode", forKey: ThemePreferences.modeKey)
      let preferences = ThemePreferences(defaults: store)
      let screen = screen(preferences)
      defer { screen.close() }
      let error = try #require(preferences.readErrors.first)
      #expect(try screen.shows(error.description))
    }
  }
#endif
