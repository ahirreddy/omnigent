import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Themes")
struct ThemeTests {
  @Test("theme colors resolve from the environment's theme and color scheme")
  func resolution() {
    var environment = EnvironmentValues()
    environment.omnigentTheme = .dracula
    environment.colorScheme = .light
    let light = ThemeColor.accent.resolve(in: environment).resolve(in: environment)
    environment.colorScheme = .dark
    let dark = ThemeColor.accent.resolve(in: environment).resolve(in: environment)
    #expect(light != dark)
    environment.omnigentTheme = .omni
    let standardDark = ThemeColor.accent.resolve(in: environment).resolve(in: environment)
    #expect(standardDark != dark)
  }

  @Test("opacity multiplies and roles survive")
  func opacity() {
    let faded = ThemeColor.failure.opacity(0.5).opacity(0.5)
    #expect(faded.alpha == 0.25)
    #expect(faded.role == ThemeColor.failure.role)
  }

  @Test("every built-in palette uses the web's id and accent")
  func palettes() {
    #expect(
      OmnigentTheme.builtIn.map(\.id) == [
        "omni", "dracula", "github", "catppuccin", "gruvbox", "solarized", "nord",
      ])
    #expect(ThemeSettingsView.hex(OmnigentTheme.omni.light.accent) == "#df3c85")
    #expect(ThemeSettingsView.hex(OmnigentTheme.dracula.dark.brandAccent) == "#ff79c6")
    #expect(ThemeSettingsView.hex(OmnigentTheme.nord.light.link) == "#355e86")
  }

  @Test("preferences use the web's keys and encodings")
  func persistence() throws {
    let suite = "omnigent.tests.theme.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = ThemePreferences(defaults: defaults)
    #expect(preferences.paletteID == "omni")
    preferences.mode = .dark
    preferences.paletteID = "dracula"
    preferences.terminal = .light
    #expect(defaults.string(forKey: "web-theme") == "dark")
    #expect(defaults.string(forKey: "omnigent:ui-theme-palette") == "\"dracula\"")
    #expect(defaults.string(forKey: "omnigent:terminal-theme") == "light")
    preferences.paletteID = "omni"
    #expect(defaults.string(forKey: "omnigent:ui-theme-palette") == nil)
    preferences.custom.contrast = 80
    let stored = try #require(defaults.string(forKey: "omnigent:custom-theme"))
    #expect(stored.contains("\"contrast\":80"))
    #expect(ThemePreferences(defaults: defaults).custom.contrast == 80)
  }

  @Test("malformed stored values are reported, not swallowed")
  func malformed() throws {
    let suite = "omnigent.tests.theme.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("not json", forKey: "omnigent:ui-theme-palette")
    defaults.set("purple", forKey: "web-theme")
    let preferences = ThemePreferences(defaults: defaults)
    #expect(preferences.paletteID == "omni")
    #expect(preferences.readErrors.contains(.malformed(key: "omnigent:ui-theme-palette")))
    #expect(preferences.readErrors.contains(.malformed(key: "web-theme")))
  }

  @Test("the custom theme derives the web's light background")
  func customDerivation() {
    let theme = CustomTheme.default.theme()
    // mix(#ffffff, #fffdff, 0.79 - 0.075) = #fffdff rounded per channel.
    #expect(ThemeSettingsView.hex(theme.light.canvas ?? .black) == "#fffeff")
    #expect(ThemeSettingsView.hex(theme.dark.canvas ?? .white) == "#0e0b19")
    var translucent = CustomTheme.default
    translucent.translucentSidebar = true
    #expect(translucent.theme().light.sidebarTint == nil)
  }

  @Test("unknown stored ids fall back to the standard theme")
  func lookup() {
    #expect(OmnigentTheme.named("does-not-exist") == .omni)
    #expect(OmnigentTheme.named(OmnigentTheme.omni.id) == .omni)
    #expect(AppearancePreference.system.colorScheme == nil)
    #expect(AppearancePreference.dark.colorScheme == .dark)
  }

  #if os(macOS)
    @Test("switching the theme restyles a rendered card")
    func rendersPerTheme() throws {
      let card = DecisionCardView(card: PreviewData.codexCommand, respond: { _ in })
      let standard = try RenderSupport.render(
        card.omnigentTheme(.omni), width: 600, scheme: .light, layout: .regular)
      let sample = try RenderSupport.render(
        card.omnigentTheme(.dracula), width: 600, scheme: .light, layout: .regular)
      #expect(standard.image.tiffRepresentation != sample.image.tiffRepresentation)
      try RenderSupport.write(sample, name: "ui-theme-sample-light")
    }
  #endif
}
