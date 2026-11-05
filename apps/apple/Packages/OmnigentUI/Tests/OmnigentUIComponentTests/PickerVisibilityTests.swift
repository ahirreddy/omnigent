import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Show in agent pickers, header menus and settings copy")
@MainActor
struct PickerVisibilityTests {
  private let entries = [
    PickerVisibilityEntry(name: "claude-native-ui", title: "Claude Code", group: .harnesses),
    PickerVisibilityEntry(name: "codex-native-ui", title: "Codex", group: .harnesses),
    PickerVisibilityEntry(name: "debby", title: "debby", group: .agents),
    PickerVisibilityEntry(name: "polly", title: "polly", group: .agents),
    PickerVisibilityEntry(name: "jcode", title: "jcode", group: .agents),
  ]

  @Test("hidden names round-trip as the web's sorted JSON array; nothing hidden stores no key")
  func storage() {
    let stored = PickerVisibility.stored(["polly", "debby"])
    #expect(stored == #"["debby","polly"]"#)
    #expect(PickerVisibility.hiddenNames(stored) == ["debby", "polly"])
    #expect(PickerVisibility.stored([]) == nil)
    #expect(PickerVisibility.hiddenNames(nil).isEmpty)
    // A corrupt value hides nothing rather than breaking the pickers.
    #expect(PickerVisibility.hiddenNames("{not json").isEmpty)
  }

  @Test("a picker drops hidden entries but keeps the selected one")
  func shownKeepsSelection() {
    let shown = PickerVisibility.shown(
      entries, name: \.name, id: \.name, selectedID: "debby", hidden: ["debby", "polly"])
    #expect(shown.map(\.name) == ["claude-native-ui", "codex-native-ui", "debby", "jcode"])
    #expect(
      PickerVisibility.shown(entries, name: \.name, id: \.name, selectedID: nil, hidden: [])
        .count == entries.count)
  }

  @Test("the summary names up to three hidden entries, as the web's")
  func summary() {
    #expect(PickerVisibility.summary(entries, hidden: []) == "Showing all 5.")
    #expect(
      PickerVisibility.summary(entries, hidden: ["codex-native-ui", "debby", "gone"])
        == "Showing 3 of 5. Hidden: Codex and debby.")
    #expect(
      PickerVisibility.summary(
        entries, hidden: ["claude-native-ui", "codex-native-ui", "debby", "polly"])
        == "Showing 1 of 5. Hidden: Claude Code, Codex, debby, and 1 more.")
  }

  @Test("the default transcript view reads Chat unless Terminal is stored")
  func transcriptViewDefault() throws {
    let name = "PickerVisibilityTests.transcriptView"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    #expect(TranscriptViewDefault.stored(in: defaults) == .chat)
    defaults.set("terminal", forKey: TranscriptViewDefault.key)
    #expect(TranscriptViewDefault.stored(in: defaults) == .terminal)
    defaults.set("grid", forKey: TranscriptViewDefault.key)
    #expect(TranscriptViewDefault.stored(in: defaults) == .chat)
  }

  @Test("the fork sheet names its run-configuration row after the harness")
  func forkModeTitle() {
    #expect(ForkOptionsSections.modeTitle(harness: "codex-native") == "Approval")
    #expect(ForkOptionsSections.modeTitle(harness: "cursor-native") == "Mode")
    #expect(ForkOptionsSections.modeTitle(harness: "claude-native") == "Permissions")
    #expect(ForkOptionsSections.modeTitle(harness: nil) == "Permissions")
  }

  @Test("the context ring's tooltip adds the token counts when they are known")
  func contextHelp() {
    #expect(ComposerTrayView.contextHelp(0.38, tokens: nil) == "38% context used")
    #expect(
      ComposerTrayView.contextHelp(0.38, tokens: ContextTokens(used: 76_000, window: 200_000))
        == "38% context used \u{00B7} 76K / 200K tokens")
    #expect(
      ComposerTrayView.contextHelp(0.6, tokens: ContextTokens(used: 612_400, window: 1_000_000))
        == "60% context used \u{00B7} 612.4K / 1M tokens")
  }

  @Test("each sharing tier has the web's explanation")
  func sharingTiers() {
    for mode in ["on", "read_only", "restricted_read_only", "off"] {
      #expect(SharingPane.tierDescription(mode) != nil)
    }
    #expect(SharingPane.tierDescription("unknown") == nil)
  }

  @Test("the compact title menu names both view modes")
  func viewModeTitles() {
    #expect(SessionViewMode.allCases.map(\.title) == ["Chat", "Terminal"])
  }
}
