#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Settings data, clicked", .serialized)
  @MainActor
  struct SettingsDataTests {
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-data-\(UUID())"))
    }

    private func file(_ text: String) throws -> URL {
      let url = FileManager.default.temporaryDirectory
        .appending(path: "settings-\(UUID()).json")
      try Data(text.utf8).write(to: url)
      return url
    }

    @Test("importing a file applies it and counts what it took")
    func importCounts() throws {
      let one = try file(#"{"version":1,"settings":{"omnigent:ui-font-size":"17"}}"#)
      defer { try? FileManager.default.removeItem(at: one) }
      #expect(
        SettingsDataSection.importSettings(from: one, to: store) == .imported("Imported 1 setting.")
      )
      #expect(store.string(forKey: "omnigent:ui-font-size") == "17")
      let two = try file(
        #"{"version":1,"settings":{"omnigent:ui-font-size":"18","omnigent:code-font-size":"12"}}"#)
      defer { try? FileManager.default.removeItem(at: two) }
      #expect(
        SettingsDataSection.importSettings(from: two, to: store)
          == .imported("Imported 2 settings."))
    }

    @Test("a broken or missing file says what's wrong and changes nothing")
    func importFailures() throws {
      let broken = try file("{")
      defer { try? FileManager.default.removeItem(at: broken) }
      let refused = SettingsDataSection.importSettings(from: broken, to: store)
      #expect(refused == .failed(SettingsPortability.ImportError.invalidJSON.description))
      let missing = FileManager.default.temporaryDirectory.appending(path: "gone-\(UUID()).json")
      guard case .failed(let message) = SettingsDataSection.importSettings(from: missing, to: store)
      else {
        Issue.record("a missing file imported")
        return
      }
      #expect(message.hasPrefix("Could not read the file:"))
      #expect(store.dictionaryRepresentation().keys.allSatisfy { !$0.hasPrefix("omnigent:") })
    }

    private func screen() -> OffscreenWindow<some View> {
      let store = store
      return settingsForm(store: store) {
        SettingsDataSection(theme: ThemePreferences(defaults: store))
      }
    }

    // The panels themselves belong to the VM flows; off screen SwiftUI presents none.
    @Test("clicking Export and Import reports no failure")
    func exportAndImport() throws {
      let screen = screen()
      defer { screen.close() }
      try screen.clickButton(at: 0)
      try screen.clickButton(at: 1)
      screen.settle(0.3)
      #expect(try !screen.shows("Could not"))
    }

    @Test("Reset asks first, then puts appearance back on the app's store")
    func reset() throws {
      let key = "omnigent:ui-font-size"
      let saved = UserDefaults.standard.object(forKey: key)
      defer { UserDefaults.standard.set(saved, forKey: key) }
      UserDefaults.standard.set("19", forKey: key)
      let screen = screen()
      defer { screen.close() }
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      try screen.clickButton(at: 2)
      #expect(SystemSideEffects.record.alertMessages.first == "Reset appearance?")
      #expect(UserDefaults.standard.string(forKey: key) == "19", "declined")
      SystemSideEffects.answer(alert: .alertFirstButtonReturn)
      try screen.clickButton(at: 2)
      #expect(UserDefaults.standard.object(forKey: key) == nil)
      #expect(try screen.shows("Appearance reset."))
    }

    @Test("what's hidden from pickers reads from the store, with the selection always kept")
    func pickerVisibility() {
      store.set(#"["Debby"]"#, forKey: PickerVisibility.key)
      let hidden = PickerVisibility.hidden(in: store)
      #expect(hidden == ["Debby"])
      let names = ["Debby", "Codex"]
      func shown(selected: String?, hiding: Set<String>) -> [String] {
        PickerVisibility.shown(
          names, name: { $0 }, id: { $0 }, selectedID: selected, hidden: hiding)
      }
      #expect(shown(selected: nil, hiding: hidden) == ["Codex"])
      #expect(shown(selected: "Debby", hiding: hidden) == names)
      #expect(shown(selected: nil, hiding: []) == names)
    }

    @Test("the interface settings offer picker visibility once a server does")
    func offersPickerVisibility() throws {
      let source = PickerVisibilitySource(server: "one") {
        .loaded([PickerVisibilityEntry(name: "codex", title: "Codex", group: .harnesses)])
      }
      let screen = settingsForm(store: store) {
        InterfaceAppearanceSections().environment(\.pickerVisibilitySource, source)
      }
      defer { screen.close() }
      #expect(try screen.shows("Default transcript view"))
      #expect(try screen.shows("Show in agent pickers"))
      let plain = settingsForm(store: store) { InterfaceAppearanceSections() }
      defer { plain.close() }
      #expect(try !plain.shows("Show in agent pickers"))
    }

    @Test("the default transcript view falls back to Chat")
    func transcriptDefault() {
      #expect(TranscriptViewDefault.stored(in: store) == .chat)
      store.set("nonsense", forKey: TranscriptViewDefault.key)
      #expect(TranscriptViewDefault.stored(in: store) == .chat)
      for choice in TranscriptViewDefault.allCases {
        store.set(choice.rawValue, forKey: TranscriptViewDefault.key)
        #expect(TranscriptViewDefault.stored(in: store) == choice)
      }
    }
  }
#endif
