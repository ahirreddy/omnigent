#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import OmnigentWorkspaceUI
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Preference sections, clicked", .serialized)
  @MainActor
  struct SettingsPreferenceSectionsTests {
    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-sections-\(UUID())"))
    }

    @Test("the send shortcut explains itself and writes its key; Always steer starts on")
    func composer() throws {
      let screen = settingsForm(store: store) { ComposerSettingsSection() }
      defer { screen.close() }
      #expect(try screen.shows("Return sends; Shift-Return"))
      let toggles = screen.switches
      try screen.click(toggles[0])
      #expect(store.bool(forKey: ComposerPreferences.submitWithCommandReturnKey))
      #expect(try screen.shows("Return inserts a new line; Command-Return sends."))
      try screen.click(toggles[1])
      #expect(store.object(forKey: ComposerPreferences.alwaysSteerKey) as? Bool == false)
    }

    @Test("automatic names start on and turn off under the web's key")
    func sessions() throws {
      let screen = settingsForm(store: store) { SessionSettingsSection() }
      defer { screen.close() }
      try screen.click(try #require(screen.switches.first))
      #expect(store.object(forKey: SessionSettingsSection.backgroundTitlesKey) as? Bool == false)
    }

    @Test("links and sub-agents each write their own key")
    func links() throws {
      let screen = settingsForm(store: store) { LinksAndSessionsSettingsSection() }
      defer { screen.close() }
      let toggles = screen.switches
      try screen.click(toggles[0])
      #expect(store.bool(forKey: InterfacePreferences.openLinksInAppKey))
      #expect(!store.bool(forKey: InterfacePreferences.openSubagentsInPanelKey))
      try screen.click(toggles[1])
      #expect(store.bool(forKey: InterfacePreferences.openSubagentsInPanelKey))
    }

    @Test("chat and workspace defaults write what's chosen")
    func appearanceDefaults() throws {
      let screen = settingsForm(store: store) { InterfaceAppearanceSections() }
      defer { screen.close() }
      try screen.click(try #require(screen.switches.first))
      #expect(store.bool(forKey: InterfacePreferences.hideUnconfiguredHarnessesKey))
      try screen.choose(
        TranscriptViewDefault.terminal.title,
        inPopUp: try #require(screen.popUps.first { $0.title == TranscriptViewDefault.chat.title }))
      #expect(
        store.string(forKey: TranscriptViewDefault.key) == TranscriptViewDefault.terminal.rawValue)
      try screen.choose(
        WorkspacePanelDefault.open.title,
        inPopUp: try #require(
          screen.popUps.first { $0.title == WorkspacePanelDefault.collapsed.title }))
      #expect(store.string(forKey: InterfacePreferences.workspacePanelKey) == "open")
      try screen.choose(
        DefaultWorkspaceTab.changes.title,
        inPopUp: try #require(screen.popUps.first { $0.title == DefaultWorkspaceTab.files.title }))
      #expect(
        store.string(forKey: InterfacePreferences.defaultWorkspaceTabKey)
          == DefaultWorkspaceTab.changes.rawValue)
    }

    @Test("the code font's size stepper, family and weight change the shared typography")
    func codeTypography() throws {
      let code = CodeTypography.shared
      let defaults = UserDefaults.standard
      defer {
        for key in [CodeTypography.sizeKey, CodeTypography.familyKey, CodeTypography.weightKey] {
          defaults.removeObject(forKey: key)
        }
        code.reload()
      }
      code.size = CodeTypography.defaultSize
      let screen = settingsForm(store: store) { InterfaceAppearanceSections() }
      defer { screen.close() }
      #expect(try screen.shows("\(Int(CodeTypography.defaultSize)) pt"))
      let stepper = try #require(screen.allViews.compactMap { $0 as? NSStepper }.first)
      let frame = stepper.convert(stepper.bounds, to: screen.host)
      try screen.click(CGPoint(x: frame.midX, y: frame.minY + 3))
      #expect(code.size == CodeTypography.defaultSize + 1)
      #expect(try screen.shows("\(Int(CodeTypography.defaultSize) + 1) pt"))
      try screen.click(CGPoint(x: frame.midX, y: frame.maxY - 3))
      #expect(code.size == CodeTypography.defaultSize)
      try screen.replaceText(in: try #require(screen.textFields.last), with: "Menlo")
      #expect(code.family == "Menlo")
      try screen.click(try #require(screen.switches.last))
      #expect(code.isHeavier)
    }

    private func pickerScreen(
      _ load: @escaping @MainActor @Sendable () async -> PickerVisibilityLoad,
      server: String = "https://one.test"
    ) -> OffscreenWindow<some View> {
      SystemSideEffects.reset()
      let source = PickerVisibilitySource(server: server, load: load)
      return OffscreenWindow(
        Form { PickerVisibilitySetting(source: source) }.formStyle(.grouped)
          .defaultAppStorage(store), width: 800, height: 400)
    }

    private var entries: [PickerVisibilityEntry] {
      [
        PickerVisibilityEntry(name: "codex", title: "Codex", group: .harnesses),
        PickerVisibilityEntry(name: "polly", title: "Polly", group: .agents),
      ]
    }

    @Test("the summary follows what's hidden, and Show All brings everything back")
    func pickerSummary() async throws {
      let entries = entries
      store.set(PickerVisibility.stored(["codex"]), forKey: PickerVisibility.key)
      let gate = AsyncGate()
      let screen = pickerScreen {
        await gate.wait()
        return .loaded(entries)
      }
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(try screen.shows("Loading agents"))
      gate.open()
      try await screen.letTasksRun()
      #expect(try screen.shows("Showing 1 of 2. Hidden: Codex."))
      // Edit, Show All.
      try screen.clickButton(at: 1)
      #expect(store.string(forKey: PickerVisibility.key) == nil)
      #expect(try screen.shows("Showing all 2."))
    }

    @Test("a server with nothing says so, and has nothing to edit")
    func pickerEmpty() async throws {
      let screen = pickerScreen { .loaded([]) }
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(try screen.shows("No agents available on this server yet."))
      #expect(screen.buttonFrames.isEmpty)
    }

    @Test("a failed read says why, and Retry reads again")
    func pickerFailure() async throws {
      let attempts = EditedValue(0)
      let entries = entries
      let screen = pickerScreen {
        attempts.value += 1
        return attempts.value == 1 ? .failed("Offline") : .loaded(entries)
      }
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(try screen.shows("Couldn't load this server's harnesses and agents: Offline"))
      try screen.clickButton(at: 0)
      try await screen.letTasksRun()
      #expect(attempts.value == 2)
      #expect(try screen.shows("Showing all 2."))
    }

    @Test("Edit opens a checklist whose switches hide and show entries")
    func pickerEditor() async throws {
      let entries = entries
      let screen = pickerScreen { .loaded(entries) }
      defer { screen.close() }
      try await screen.letTasksRun()
      try screen.clickButton(at: 0)
      screen.settle(0.3)
      #expect(screen.window.attachedSheet != nil)
      #expect(try screen.shows("Codex"))
      #expect(try screen.shows("Polly"))
      #expect(try screen.shows("Harnesses"))
      // Checkboxes in this list, which only draw their box as an AppKit button.
      let boxes = screen.allViews.compactMap { $0 as? NSButton }.filter {
        String(describing: type(of: $0)) == "FocusRingNSButton"
      }
      try #require(boxes.count == 2)
      try screen.click(boxes[1])
      #expect(PickerVisibility.hiddenNames(store.string(forKey: PickerVisibility.key)) == ["polly"])
      try screen.click(boxes[1])
      #expect(store.string(forKey: PickerVisibility.key) == nil)
      let filter = try #require(screen.allViews.compactMap { $0 as? NSSearchField }.first)
      try screen.replaceText(in: filter, with: "pol")
      #expect(try screen.shows("Polly"))
      #expect(try !screen.shows("Codex"))
      #expect(try !screen.shows("Harnesses"), "a section with no match goes")
      let done = try #require(screen.buttonFrames.last)
      try screen.click(CGPoint(x: done.midX, y: done.midY))
      screen.settle(0.3)
      #expect(screen.window.attachedSheet == nil)
    }

    /// The setting over a source a test can replace, as switching servers does.
    private struct ServerSwitchingSetting: View {
      let source: EditedValue<PickerVisibilitySource>
      let store: UserDefaults

      var body: some View {
        Form { PickerVisibilitySetting(source: source.value) }.formStyle(.grouped)
          .defaultAppStorage(store)
      }
    }

    @Test("switching to a server that fails doesn't keep showing the last server's agents")
    func pickerServerSwitch() async throws {
      let entries = entries
      let source = EditedValue(PickerVisibilitySource(server: "one") { .loaded(entries) })
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        ServerSwitchingSetting(source: source, store: store), width: 800, height: 400)
      defer { screen.close() }
      try await screen.letTasksRun()
      #expect(try screen.shows("Showing all 2."))
      source.value = PickerVisibilitySource(server: "two") { .failed("Offline") }
      try await screen.letTasksRun()
      #expect(try !screen.shows("Showing all 2."))
      #expect(try screen.shows("Couldn't load this server's harnesses and agents: Offline"))
      // Retry, then Edit and Show All are off with nothing to edit.
      #expect(screen.buttonFrames.count == 1)
    }

    @Test("a slow answer from the last server can't replace this server's")
    func pickerSlowAnswer() async throws {
      let entries = entries
      let gate = AsyncGate()
      let source = EditedValue(
        PickerVisibilitySource(server: "one") {
          await gate.wait()
          return .failed("The last server")
        })
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        ServerSwitchingSetting(source: source, store: store), width: 800, height: 400)
      defer { screen.close() }
      try await screen.letTasksRun()
      source.value = PickerVisibilitySource(server: "two") { .loaded(entries) }
      try await screen.letTasksRun()
      gate.open()
      try await screen.letTasksRun()
      #expect(try screen.shows("Showing all 2."))
      #expect(try !screen.shows("The last server"))
    }
  }
#endif
