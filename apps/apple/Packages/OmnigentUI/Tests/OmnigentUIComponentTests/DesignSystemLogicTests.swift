import Foundation
import SwiftUI
import Testing

@testable import OmnigentUIComponents

@Suite("Design system rules")
struct DesignSystemLogicTests {
  @Test(
    "a harness id or alias resolves to its label and monogram",
    arguments: [
      ("codex", "codex", "Codex", "C"), ("codex-native", "codex", "Codex", "C"),
      (" CODEX-Native\n", "codex", "Codex", "C"), ("claude", "claude", "Claude Code", "C"),
      ("claude-native", "claude", "Claude Code", "C"),
      ("claude-sdk", "claude-sdk", "Claude SDK", "C"),
      ("cursor-sdk", "cursor", "Cursor", "C"), ("kiro", "kiro", "Kiro", "K"),
      ("opencode", "opencode", "OpenCode", "OC"), ("native-kimi", "kimi", "Kimi", "K"),
      ("agy", "antigravity", "Antigravity", "A"), ("native-goose", "goose", "Goose", "G"),
      ("pi-native", "pi", "Pi", "P"), ("hermes", "hermes", "Hermes", "H"),
      ("openai-agents", "openai-agents", "OpenAI Agents", "OA"),
      ("my-custom-harness", "fallback", "My Custom Harness", "M"),
      ("pipeline", "fallback", "Pipeline", "P"), ("", "fallback", "Agent", "A"),
      ("   ", "fallback", "Agent", "A"),
    ])
  func harnessAppearance(raw: String, identifier: String, label: String, monogram: String) {
    let appearance = HarnessAppearance(harness: raw)
    #expect(appearance.identifier == identifier)
    #expect(appearance.label == label)
    #expect(appearance.monogram == monogram)
  }

  @Test("a harness with no id is an agent; only Claude has a brand tint and Codex a gradient")
  func harnessDefaults() {
    #expect(HarnessAppearance(harness: nil).label == "Agent")
    #expect(HarnessAppearance(harness: "claude").tint != nil)
    #expect(HarnessAppearance(harness: "claude-sdk").tint != nil)
    #expect(HarnessAppearance(harness: "codex").tint == nil)
    #expect(HarnessAppearance(harness: "codex").usesCodexGradient)
    #expect(HarnessAppearance(harness: "openai-agents").usesCodexGradient)
    #expect(!HarnessAppearance(harness: "claude").usesCodexGradient)
  }

  @Test("a name made only of punctuation still has a visible label and monogram")
  func harnessPunctuationName() {
    let appearance = HarnessAppearance(harness: "-native")
    #expect(appearance.label == "Native")
    #expect(appearance.monogram == "N")
    #expect(HarnessAppearance(harness: "---").label == "Agent")
  }

  @Test("built-in native agents show their harness; any other keeps its name")
  func agentNames() {
    #expect(HarnessAppearance.agentName("codex-native-ui", harness: nil) == "Codex")
    #expect(HarnessAppearance.agentName("x-native-ui", harness: "claude") == "Claude Code")
    #expect(HarnessAppearance.agentName("reviewer", harness: "claude") == "reviewer")
    #expect(HarnessAppearance.agentName("-native-ui", harness: nil) == "Native")
  }

  @Test("a status leads with what needs the user, then what runs, then what failed")
  func statusPrecedence() {
    func label(
      _ status: SessionListStatus, readOnly: Bool = false, failure: String? = nil, pending: Int = 0
    ) -> String {
      StatusPresentation.session(
        status: status, isReadOnly: readOnly, failure: failure, pending: pending
      ).label
    }
    #expect(label(.idle, failure: "x", pending: 1) == "Needs you")
    #expect(label(.needsResponse) == "Needs you")
    #expect(label(.running, failure: "x") == "Running")
    #expect(label(.idle, readOnly: true, failure: "x") == "Needs attention")
    #expect(label(.idle, readOnly: true) == "Read only")
    #expect(label(.idle) == "Idle")
  }

  @Test("hex parses #rrggbb and reads anything else as black")
  func hexParsing() {
    #expect(RGB(hex: "#ff8000") == RGB(red: 255, green: 128, blue: 0))
    #expect(RGB(hex: "ff8000") == RGB(red: 255, green: 128, blue: 0))
    for hostile in ["", "#", "#fff", "#gggggg", "#ff80000", "red", "\u{202E}#ff8000", "👩‍👩‍👧‍👦"] {
      #expect(RGB(hex: hostile) == RGB(red: 0, green: 0, blue: 0), "\(hostile)")
    }
    #expect(
      RGB.mix(RGB(hex: "#000000"), RGB(hex: "#ffffff"), 2) == RGB(red: 255, green: 255, blue: 255))
    #expect(RGB.mix(RGB(hex: "#000000"), RGB(hex: "#ffffff"), -1) == RGB(red: 0, green: 0, blue: 0))
  }

  @Test("a custom theme survives any contrast, and translucent sidebars drop the tint")
  func customThemeExtremes() {
    for contrast in [-1e9, 0, 50, 100, 1e9, Double.nan, Double.infinity] {
      var custom = CustomTheme.default
      custom.contrast = contrast
      let theme = custom.theme()
      #expect(theme.id == "custom")
      #expect(theme.light.sidebarTint != nil)
    }
    var translucent = CustomTheme.default
    translucent.translucentSidebar = true
    #expect(translucent.theme().light.sidebarTint == nil)
    #expect(translucent.theme().dark.sidebarTint == nil)
    var unknownBase = CustomTheme.default
    unknownBase.basePalette = "no-such-palette"
    #expect(unknownBase.theme().id == "custom")
  }

  @Test("stored palettes decode only as the web writes them")
  func paletteDecoding() throws {
    #expect(try ThemePreferences.decodePalette(nil).get() == OmnigentTheme.omni.id)
    #expect(try ThemePreferences.decodePalette(#""nord""#).get() == "nord")
    #expect(try ThemePreferences.decodePalette(#""custom""#).get() == "custom")
    let malformed = ThemePreferences.ReadError.malformed(key: ThemePreferences.paletteKey)
    for hostile in ["nord", #""not-a-theme""#, "", "{}", "1", "\u{0}"] {
      #expect(ThemePreferences.decodePalette(hostile) == .failure(malformed), "\(hostile)")
    }
    #expect(malformed.description.contains(ThemePreferences.paletteKey))
  }

  @Test("a theme file with a bad value is reported after a reload, and reset clears the report")
  func reloadReportsErrors() throws {
    let store = try #require(UserDefaults(suiteName: "design-system-\(UUID())"))
    let preferences = ThemePreferences(defaults: store)
    #expect(preferences.readErrors.isEmpty)
    store.set("purple", forKey: ThemePreferences.modeKey)
    store.set("{", forKey: ThemePreferences.customKey)
    store.set("neon", forKey: ThemePreferences.terminalKey)
    store.set("not-json", forKey: ThemePreferences.paletteKey)
    preferences.reload(from: store)
    #expect(preferences.readErrors.count == 4)
    #expect(preferences.mode == .system)
    #expect(preferences.terminal == .auto)
    #expect(preferences.paletteID == OmnigentTheme.omni.id)
    SettingsPortability.resetAppearance(store)
    preferences.reload(from: store)
    #expect(preferences.readErrors.isEmpty, "the warning outlived the reset")
  }

  @Test("a reload assigns what changed, and each change is written back under the web's keys")
  func reloadFollowsStore() throws {
    let store = try #require(UserDefaults(suiteName: "design-system-\(UUID())"))
    let preferences = ThemePreferences(defaults: store)
    store.set("dark", forKey: ThemePreferences.modeKey)
    store.set("light", forKey: ThemePreferences.terminalKey)
    store.set(#""nord""#, forKey: ThemePreferences.paletteKey)
    preferences.reload(from: store)
    #expect(preferences.mode == .dark)
    #expect(preferences.terminal == .light)
    #expect(preferences.paletteID == "nord")
    #expect(preferences.theme.id == "nord")
    #expect(preferences.themes.last?.id == "custom")
    preferences.paletteID = #"we"ird\"#
    #expect(store.string(forKey: ThemePreferences.paletteKey) == #""we\"ird\\""#)
    preferences.paletteID = OmnigentTheme.omni.id
    #expect(store.object(forKey: ThemePreferences.paletteKey) == nil)
    #expect(TerminalThemePreference.allCases.map(\.title) == ["Match app", "Light", "Dark"])
    #expect(TerminalThemePreference.allCases.map(\.id) == TerminalThemePreference.allCases)
  }

  @Test("a color's hex round-trips through the gamma encoding")
  func colorHex() {
    for hex in ["#000000", "#ffffff", "#df3c85", "#0e0b19", "#010203"] {
      #expect(ThemeSettingsView.hex(RGB(hex: hex).color) == hex)
    }
  }

  @Test("the tokens differ between light and dark")
  func tokens() {
    #expect(DesignTokens.background(.dark) == DesignTokens.darkBackground)
    #expect(DesignTokens.background(.light) == DesignTokens.lightBackground)
    #expect(DesignTokens.foreground(.dark) == DesignTokens.darkForeground)
    #expect(DesignTokens.foreground(.light) == DesignTokens.lightForeground)
    #expect(DesignTokens.mutedForeground(.dark) == DesignTokens.darkMutedForeground)
    #expect(DesignTokens.mutedForeground(.light) == DesignTokens.lightMutedForeground)
    #expect(DesignTokens.border(.dark) == DesignTokens.darkBorder)
    #expect(DesignTokens.border(.light) == DesignTokens.lightBorder)
  }

  @Test("the mascot's path parser survives malformed data")
  func svgPathHostile() {
    for hostile in [
      "", "M", "M1", "M1 2 3", "L1,2", "C1 2 3 4 5", "Z", "Q1 2", "M1e5-2e-3L-4-5Z", "M\u{0}1 2",
      "M 1 2 C 3 4 5 6 7 8 9", "👩‍👩‍👧‍👦", "M--1 2",
    ] {
      _ = SVGPath.parse(hostile)
    }
    #expect(!SVGPath.parse("M0 0L10 0L10 10Z").isEmpty)
    #expect(SVGPath.parse("").isEmpty)
    #expect(SVGPath.parse("M0 0L10 10").boundingRect == CGRect(x: 0, y: 0, width: 10, height: 10))
    #expect(
      SVGPath.parse("M-1e1 0L10-10").boundingRect == CGRect(x: -10, y: -10, width: 20, height: 10))
  }

  @Test("a banner's id tells repeats of the same message apart")
  func bannerIdentity() {
    let first = TransientBanner(message: "Copied")
    let second = TransientBanner(message: "Copied", actionTitle: "Open")
    #expect(first.id != second.id)
    #expect(second.actionTitle == "Open")
  }

  @Test("copy actions are equal for the same window's presenter")
  @MainActor
  func copyActionIdentity() {
    let presenter = CopyConfirmationPresenter()
    let action = CopyAction(presenter: presenter)
    #expect(action == CopyAction(presenter: presenter))
    #expect(action != CopyAction(presenter: CopyConfirmationPresenter()))
    #expect(action != CopyAction(presenter: nil))
  }
}
