import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Settings data and archived retention")
@MainActor
struct SettingsPortabilityTests {
  private func emptyDefaults(_ name: String) throws -> UserDefaults {
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("export writes the web's file: text values, Booleans as true/false, no other keys")
  func exportMatchesTheWebFormat() throws {
    let defaults = try emptyDefaults("SettingsPortabilityTests.export")
    defaults.set("dark", forKey: "web-theme")
    defaults.set(true, forKey: GitPreferences.alwaysUseWorktreeKey)
    defaults.set(14.0, forKey: "omnigent:ui-font-size")
    defaults.set("nope", forKey: "omnigent:not-exported")
    let data = try SettingsPortability.export(defaults)
    let file = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(file["version"] as? Int == 1)
    #expect(
      file["settings"] as? [String: String]
        == [
          "web-theme": "dark", GitPreferences.alwaysUseWorktreeKey: "true",
          "omnigent:ui-font-size": "14",
        ])
    // The app reads back its own file.
    #expect(try SettingsPortability.settings(in: data).count == 3)
  }

  @Test("a file with an unknown key, a non-text value or no version is not imported")
  func importValidatesLikeTheWeb() {
    #expect(throws: SettingsPortability.ImportError.invalidJSON) {
      try SettingsPortability.settings(in: Data("{".utf8))
    }
    for body in [
      #"{"settings":{}}"#, #"{"version":1,"settings":{"evil":"x"}}"#,
      #"{"version":1,"settings":{"web-theme":3}}"#, #"{"version":0,"settings":{}}"#,
    ] {
      #expect(throws: SettingsPortability.ImportError.notSettings) {
        try SettingsPortability.settings(in: Data(body.utf8))
      }
    }
  }

  @Test("import overwrites: omitted keys reset, Booleans and numbers keep the app's types")
  func importOverwrites() throws {
    let defaults = try emptyDefaults("SettingsPortabilityTests.import")
    defaults.set("light", forKey: "omnigent:terminal-theme")
    defaults.set(14.0, forKey: "omnigent:ui-font-size")
    let count = SettingsPortability.apply(
      [
        GitPreferences.alwaysUseWorktreeKey: "true",
        GitPreferences.deleteWorktreesOnArchiveKey: "false",
        "omnigent:ui-font-size": "16", "web-theme": "dark",
      ], to: defaults)
    #expect(count == 4)
    #expect(defaults.object(forKey: "omnigent:terminal-theme") == nil)
    #expect(defaults.object(forKey: GitPreferences.alwaysUseWorktreeKey) as? Bool == true)
    #expect(defaults.string(forKey: GitPreferences.deleteWorktreesOnArchiveKey) == "false")
    #expect(defaults.object(forKey: "omnigent:ui-font-size") as? Double == 16)
    #expect(defaults.string(forKey: "web-theme") == "dark")
  }

  @Test("reset clears appearance and keeps Git defaults")
  func resetClearsOnlyAppearance() throws {
    let defaults = try emptyDefaults("SettingsPortabilityTests.reset")
    defaults.set("dark", forKey: ThemePreferences.modeKey)
    defaults.set("main", forKey: GitPreferences.defaultBaseBranchKey)
    let theme = ThemePreferences(defaults: defaults)
    #expect(theme.mode == .dark)
    SettingsPortability.resetAppearance(defaults)
    theme.reload(from: defaults)
    #expect(theme.mode == .system)
    #expect(defaults.string(forKey: GitPreferences.defaultBaseBranchKey) == "main")
  }

  @Test("retention marks only the caller's sessions past the cutoff as expired")
  func retentionExpiresOwnedOldSessions() {
    let now = Date(timeIntervalSince1970: 1_793_880_000)
    let day: Int64 = 86_400
    let stamp = Int64(now.timeIntervalSince1970)
    var old = PreviewData.sessions[0]
    old.id = "old"
    var others = old
    others.id = "others"
    var fresh = old
    fresh.id = "fresh"
    let info = [
      "old": ArchivedSessionInfo(archivedAt: stamp - 40 * day, canDelete: true),
      "others": ArchivedSessionInfo(archivedAt: stamp - 40 * day, canDelete: false),
      "fresh": ArchivedSessionInfo(archivedAt: stamp - 2 * day, canDelete: true),
    ]
    let sessions = [old, others, fresh]
    #expect(ArchivedRetention.expired(sessions, info: info, days: 30, now: now) == ["old"])
    #expect(ArchivedRetention.expired(sessions, info: info, days: nil, now: now).isEmpty)
    #expect(ArchivedRetention.days("30") == 30)
    #expect(ArchivedRetention.days("0") == nil && ArchivedRetention.days("soon") == nil)
    #expect(ArchivedRetention.title(nil) == "Never" && ArchivedRetention.title(7) == "After 7 days")
  }
}
