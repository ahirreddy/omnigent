import Foundation
import Testing

@testable import OmnigentTerminalUI

@Suite("Hostile terminal configuration", .serialized)
struct HostileConfigTests {
  private func configLines(_ appearance: TerminalAppearance) -> Set<String> {
    Set(
      GhosttyConfigText.make(appearance, systemFontFamily: nil)
        .split(separator: "\n").map(String.init))
  }

  @Test("font sizes print whole or to one decimal, including NaN and negatives")
  func fontSizeText() {
    #expect(configLines(TerminalAppearance(fontSize: 0)).contains("font-size = 0"))
    #expect(configLines(TerminalAppearance(fontSize: -3)).contains("font-size = -3"))
    #expect(configLines(TerminalAppearance(fontSize: 13.04)).contains("font-size = 13.0"))
    #expect(!configLines(TerminalAppearance(fontSize: .nan)).contains { $0.hasPrefix("font-size") })
    #expect(configLines(TerminalAppearance(fontSize: 1e-300)).contains("font-size = 0.0"))
  }

  @Test("an infinite font size prints")
  func infiniteFontSize() {
    #expect(
      !GhosttyConfigText.make(TerminalAppearance(fontSize: .infinity), systemFontFamily: nil)
        .isEmpty)
  }

  @Test("a font size past Int prints")
  func fontSizePastInt() {
    #expect(
      !GhosttyConfigText.make(TerminalAppearance(fontSize: 1e300), systemFontFamily: nil).isEmpty)
  }

  @Test("quotes cannot end the font family's string")
  func quotedFamily() {
    let lines = configLines(TerminalAppearance(fontFamily: "Me\"nlo\"\""))
    #expect(lines.contains("font-family = \"Menlo\""))
  }

  @Test(
    "a newline in a font family cannot add a configuration line")
  func familyCannotInjectLines() {
    let lines = configLines(TerminalAppearance(fontFamily: "Menlo\nclipboard-write = allow\nx"))
    #expect(!lines.contains("clipboard-write = allow"))
  }

  @Test("an empty family names no font, whatever the system font is")
  func emptyFamily() {
    let text = GhosttyConfigText.make(
      TerminalAppearance(fontFamily: ""), systemFontFamily: "SF Mono")
    #expect(!text.contains("font-family"))
    #expect(
      GhosttyConfigText.make(TerminalAppearance(), systemFontFamily: "").contains("font-family")
        == false)
  }

  @Test("both palettes carry sixteen ANSI colors in #rrggbb")
  func palettes() {
    for palette in [TerminalPalette.dark, TerminalPalette.light] {
      #expect(palette.ansi.count == 16)
      let colors =
        palette.ansi + [palette.background, palette.foreground, palette.cursor, palette.selection]
      for color in colors {
        #expect(color.count == 7 && color.hasPrefix("#"), "\(color)")
      }
    }
    #expect(TerminalAppearance(colorScheme: .light).palette == .light)
    #expect(TerminalAppearance(colorScheme: .dark).palette == .dark)
  }

  @Test("libghostty survives validating odd font sizes and families")
  func validateOddAppearances() throws {
    _ = try GhosttyRuntime.shared()
    let appearances = [
      TerminalAppearance(fontSize: 0), TerminalAppearance(fontSize: -3),
      TerminalAppearance(fontSize: .nan), TerminalAppearance(fontSize: 1e15),
      TerminalAppearance(fontSize: 0.0001), TerminalAppearance(fontFamily: ""),
      TerminalAppearance(fontFamily: String(repeating: "W", count: 100_000)),
      TerminalAppearance(fontFamily: "\u{0}"), TerminalAppearance(fontFamily: "\\"),
      TerminalAppearance(fontFamily: "👩‍👩‍👧‍👦"),
    ]
    for appearance in appearances {
      do {
        try GhosttyRuntime.validate(appearance)
      } catch {
        #expect(!error.description.isEmpty)
      }
    }
  }

  @Test(
    "validating before the runtime starts reports instead of crashing")
  func validateFirst() throws {
    try GhosttyRuntime.validate(TerminalAppearance())
  }

  @Test("each libghostty error reads as a sentence")
  func errorDescriptions() {
    #expect(GhosttyError.initFailed(code: .min).description.contains("-2147483648"))
    #expect(!GhosttyError.appCreationFailed.description.isEmpty)
    #expect(!GhosttyError.surfaceCreationFailed.description.isEmpty)
    #expect(GhosttyError.invalidConfiguration([]).description.hasSuffix(": "))
    #expect(GhosttyError.invalidConfiguration(["a", "b"]).description.hasSuffix("a; b"))
  }

  @Test("scrollback labels and identities")
  func scrollback() {
    #expect(TerminalScrollback.allCases.map(\.label) == ["2 MB", "10 MB", "50 MB"])
    #expect(TerminalScrollback.allCases.allSatisfy { $0.id == $0.rawValue })
  }
}

@Suite("Hostile stored terminal settings", .serialized)
struct HostilePreferencesTests {
  private func emptyDefaults(_ name: String) throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("stored values of the wrong type or out of range are ignored")
  func wrongTypes() throws {
    let defaults = try emptyDefaults("HostilePreferencesTests.types")
    let base = TerminalAppearance()
    for size: Any in ["13", Double.nan, Double.infinity, -1.0, 7.99, 32.01, Data()] {
      defaults.set(size, forKey: TerminalPreferences.fontSizeKey)
      #expect(TerminalPreferences.load(over: base, defaults: defaults) == base, "\(size)")
    }
    defaults.removeObject(forKey: TerminalPreferences.fontSizeKey)
    for scrollback: Any in ["2000000", -1, Int.max, 2_000_001] {
      defaults.set(scrollback, forKey: TerminalPreferences.scrollbackKey)
      #expect(TerminalPreferences.load(over: base, defaults: defaults) == base, "\(scrollback)")
    }
    defaults.set("", forKey: TerminalPreferences.fontFamilyKey)
    #expect(TerminalPreferences.load(over: base, defaults: defaults).fontFamily == nil)
    defaults.set(["not a string"], forKey: TerminalThemeMode.key)
    #expect(
      TerminalPreferences.load(over: base, defaults: defaults).colorScheme == base.colorScheme)
  }

  @Test("the edges of the font size range are kept")
  func sizeRangeEdges() throws {
    let defaults = try emptyDefaults("HostilePreferencesTests.edges")
    for size in [8.0, 32.0, 8.5] {
      defaults.set(size, forKey: TerminalPreferences.fontSizeKey)
      #expect(
        TerminalPreferences.load(over: TerminalAppearance(), defaults: defaults).fontSize == size)
    }
  }

  @Test("the theme mode keeps only what the web writes")
  func themeModes() {
    #expect(TerminalThemeMode(stored: nil) == .auto)
    #expect(TerminalThemeMode(stored: "") == .auto)
    #expect(TerminalThemeMode(stored: "DARK") == .auto)
    #expect(TerminalThemeMode(stored: "dark") == .dark)
    #expect(TerminalThemeMode.auto.resolved(app: .light) == .light)
    #expect(TerminalThemeMode.light.resolved(app: .dark) == .light)
    #expect(TerminalThemeMode.dark.resolved(app: .light) == .dark)
  }

  @Test("saving twice leaves the same settings, and a merge keeps the runtime's colors")
  func saveAndMerge() throws {
    let defaults = try emptyDefaults("HostilePreferencesTests.save")
    let edited = TerminalAppearance(
      fontFamily: "Menlo", fontSize: 20, colorScheme: .light, scrollback: .small,
      optionAsAlt: false, cursorBlink: false)
    TerminalPreferences.save(edited, defaults: defaults)
    TerminalPreferences.save(edited, defaults: defaults)
    #expect(defaults.double(forKey: TerminalPreferences.fontSizeKey) == 20)
    let merged = TerminalPreferences.merge(edited, into: TerminalAppearance(colorScheme: .dark))
    #expect(merged.colorScheme == .dark)
    #expect(merged.fontFamily == "Menlo")
  }

  @Test("clipboard policy titles and identities")
  func clipboardPolicy() {
    #expect(Set(TerminalClipboardPolicy.allCases.map(\.title)).count == 3)
    #expect(TerminalClipboardPolicy.allCases.allSatisfy { $0.id == $0 })
  }
}
