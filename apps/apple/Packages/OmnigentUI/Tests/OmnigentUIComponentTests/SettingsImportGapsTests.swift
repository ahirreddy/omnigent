#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Importing sessions, in progress", .serialized)
  @MainActor
  struct SettingsImportGapsTests {
    @Test("While an import runs a spinner shows and Import is off, then the result shows")
    func importInProgress() async throws {
      let (gate, open) = AsyncStream<Void>.makeStream()
      var actions = ServerSettingsActions()
      actions.importSessions = { _, _, _, _ in
        for await _ in gate { break }
        return "Imported 1"
      }
      let store = try #require(UserDefaults(suiteName: "import-progress-\(UUID())"))
      let screen = settingsForm(store: store) {
        ImportSessionsPane(
          hosts: [SettingChoice(id: "m1", title: "Build Mac")],
          sources: [SettingChoice(id: "all", title: "All harnesses")], actions: actions)
      }
      defer { screen.close() }
      try screen.clickButton(at: 0)
      try await screen.letTasksRun()
      #expect(screen.allViews.contains { $0 is NSProgressIndicator })
      #expect(screen.buttonFrames.isEmpty, "Import is off while one runs")
      open.yield()
      try await screen.letTasksRun()
      #expect(try screen.shows("Imported 1"))
      #expect(!screen.allViews.contains { $0 is NSProgressIndicator })
    }
  }
#endif
