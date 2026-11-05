import Foundation
import Testing

@testable import OmnigentTerminalUI

@Suite("Terminal preferences")
struct TerminalPreferencesTests {
  private func emptyDefaults(_ name: String) throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("font, scrollback, Option as Alt and blink survive a relaunch")
  func savedSettingsLoadOverTheSystemAppearance() throws {
    let defaults = try emptyDefaults("TerminalPreferencesTests.roundTrip")
    let base = TerminalAppearance(fontSize: 13, colorScheme: .light)
    #expect(TerminalPreferences.load(over: base, defaults: defaults) == base)

    var edited = base
    edited.fontSize = 17
    edited.fontFamily = "Menlo"
    edited.scrollback = .large
    edited.optionAsAlt = false
    edited.cursorBlink = false
    TerminalPreferences.save(edited, defaults: defaults)
    #expect(TerminalPreferences.load(over: base, defaults: defaults) == edited)

    // Back to the system font removes the stored family.
    edited.fontFamily = nil
    TerminalPreferences.save(edited, defaults: defaults)
    #expect(defaults.object(forKey: TerminalPreferences.fontFamilyKey) == nil)
  }

  @Test("out-of-range stored values are ignored")
  func invalidStoredValuesFallBack() throws {
    let defaults = try emptyDefaults("TerminalPreferencesTests.invalid")
    defaults.set(400.0, forKey: TerminalPreferences.fontSizeKey)
    defaults.set(7, forKey: TerminalPreferences.scrollbackKey)
    let base = TerminalAppearance()
    #expect(TerminalPreferences.load(over: base, defaults: defaults) == base)
  }

  @Test("the web's terminal theme pins the colors; auto and unknown values follow the app")
  func terminalThemePinsTheScheme() throws {
    let defaults = try emptyDefaults("TerminalPreferencesTests.theme")
    let light = TerminalAppearance(colorScheme: .light)
    defaults.set("dark", forKey: TerminalThemeMode.key)
    #expect(TerminalPreferences.load(over: light, defaults: defaults).colorScheme == .dark)
    defaults.set("sepia", forKey: TerminalThemeMode.key)
    #expect(TerminalPreferences.load(over: light, defaults: defaults).colorScheme == .light)
    #expect(TerminalThemeMode.light.resolved(app: .dark) == .light)
    #expect(TerminalThemeMode.auto.resolved(app: .dark) == .dark)
  }

  @Test("settings edits keep the runtime's current colors")
  func mergeKeepsTheCurrentScheme() {
    let current = TerminalAppearance(fontSize: 13, colorScheme: .dark)
    let edited = TerminalAppearance(fontSize: 20, colorScheme: .light)
    let merged = TerminalPreferences.merge(edited, into: current)
    #expect(merged.fontSize == 20 && merged.colorScheme == .dark)
  }
}
