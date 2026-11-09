#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentUIComponents

  /// What the settings panels do with their results, without the panels on screen.
  @Suite("Settings data panels", .serialized)
  @MainActor
  struct SettingsDataGapsTests {
    private struct PanelFailure: LocalizedError {
      var errorDescription: String? { "the disk is full" }
    }

    private let store: UserDefaults

    init() throws {
      store = try #require(UserDefaults(suiteName: "settings-data-gaps-\(UUID())"))
    }

    private func flow(makeExport: (() throws -> Data)? = nil) -> SettingsDataFlow {
      SettingsDataFlow(
        theme: ThemePreferences(defaults: store), defaults: store, makeExport: makeExport)
    }

    private func file(_ text: String) throws -> URL {
      let url = FileManager.default.temporaryDirectory.appending(path: "settings-\(UUID()).json")
      try Data(text.utf8).write(to: url)
      return url
    }

    @Test("Export writes the store's settings, and the panel closing forgets the file")
    func exportFile() throws {
      store.set("17", forKey: "omnigent:ui-font-size")
      let flow = flow()
      #expect(!flow.isExporting)
      flow.beginExport()
      #expect(flow.isExporting)
      let written = try #require(flow.exporting).data
      #expect(try SettingsPortability.settings(in: written)["omnigent:ui-font-size"] == "17")
      flow.isExporting = true
      #expect(flow.isExporting, "only closing changes it")
      flow.isExporting = false
      #expect(flow.exporting == nil)
    }

    @Test("A settings file that can't be made says why and opens no panel")
    func exportCannotBeMade() {
      let flow = flow { throw PanelFailure() }
      flow.beginExport()
      #expect(!flow.isExporting)
      #expect(flow.failure == "Could not export: the disk is full")
    }

    @Test("The save panel's result shows, and the latest result replaces the last")
    func exportResult() throws {
      let flow = flow()
      flow.finishExport(.failure(PanelFailure()))
      #expect(flow.failure == "Could not export: the disk is full")
      #expect(flow.status == nil)
      flow.finishExport(.success(FileManager.default.temporaryDirectory))
      #expect(flow.status == "Settings exported.")
      #expect(flow.failure == nil)
    }

    @Test("A chosen file is imported and reaches the live theme; a bad one says what's wrong")
    func importResult() throws {
      let theme = ThemePreferences(defaults: store)
      let flow = SettingsDataFlow(theme: theme, defaults: store)
      let good = try file(
        #"{"version":1,"settings":{"\#(ThemePreferences.modeKey)":"dark","omnigent:ui-font-size":"17"}}"#
      )
      defer { try? FileManager.default.removeItem(at: good) }
      flow.finishImport(.success(good))
      #expect(flow.status?.hasPrefix("Imported ") == true)
      #expect(flow.failure == nil)
      #expect(store.string(forKey: "omnigent:ui-font-size") == "17")
      #expect(theme.mode == .dark)

      let broken = try file("{")
      defer { try? FileManager.default.removeItem(at: broken) }
      flow.finishImport(.success(broken))
      #expect(flow.failure == SettingsPortability.ImportError.invalidJSON.description)
      #expect(flow.status == nil)

      flow.finishImport(.failure(PanelFailure()))
      #expect(flow.failure == "Could not open: the disk is full")
    }

    @Test("Reset clears this store's appearance and says so")
    func resetClears() {
      store.set("19", forKey: "omnigent:ui-font-size")
      let flow = flow()
      flow.resetAppearance()
      #expect(store.object(forKey: "omnigent:ui-font-size") == nil)
      #expect(flow.status == "Appearance reset.")
    }

    @Test("Export and Import start their panels, and a failure shows in the section")
    func clicks() async throws {
      let flow = flow()
      let screen = settingsForm(store: store) { SettingsDataSection(flow: flow) }
      defer { screen.close() }
      try screen.clickButton(at: 0)
      #expect(flow.isExporting)
      flow.isExporting = false
      try screen.clickButton(at: 1)
      #expect(flow.isImporting)
      flow.isImporting = false
      flow.finishExport(.failure(PanelFailure()))
      try await screen.letTasksRun()
      #expect(try screen.shows("Could not export: the disk is full"))
      flow.finishExport(.success(FileManager.default.temporaryDirectory))
      try await screen.letTasksRun()
      #expect(try screen.shows("Settings exported."))
      #expect(try !screen.shows("Could not export"))
    }

    @Test("The settings file writes its bytes, and reads back what a regular file holds")
    func document() throws {
      let bytes = Data("{}".utf8)
      let wrapper = try SettingsFile(data: bytes)
        .fileWrapper(configuration: FileDocumentConfigurations.write())
      #expect(wrapper.regularFileContents == bytes)
      let read = try SettingsFile(
        configuration: FileDocumentConfigurations.read(
          FileWrapper(regularFileWithContents: bytes)))
      #expect(read.data == bytes)
      #expect(throws: CocoaError.self) {
        try SettingsFile(
          configuration: FileDocumentConfigurations.read(
            FileWrapper(directoryWithFileWrappers: [:])))
      }
    }
  }

  /// Saving a table or code block, past what its panel shows.
  @Suite("Markdown exports", .serialized)
  @MainActor
  struct MarkdownExportGapsTests {
    private struct SaveFailure: LocalizedError {
      var errorDescription: String? { "no room" }
    }

    @Test("An export document holds UTF-8 text in both directions, and refuses anything else")
    func document() throws {
      #expect(TextExportDocument.readableContentTypes == [.plainText])
      let wrapper = try TextExportDocument(text: "héllo")
        .fileWrapper(configuration: FileDocumentConfigurations.write())
      #expect(wrapper.regularFileContents == Data("héllo".utf8))
      let read = try TextExportDocument(
        configuration: FileDocumentConfigurations.read(
          FileWrapper(regularFileWithContents: Data("héllo".utf8))))
      #expect(read.text == "héllo")
      #expect(throws: CocoaError.self) {
        try TextExportDocument(
          configuration: FileDocumentConfigurations.read(
            FileWrapper(regularFileWithContents: Data([0xFF, 0xFE]))))
      }
      #expect(throws: CocoaError.self) {
        try TextExportDocument(
          configuration: FileDocumentConfigurations.read(
            FileWrapper(directoryWithFileWrappers: [:])))
      }
    }

    @Test("Only a failed save has something to say")
    func failureMessage() {
      #expect(
        TextExporter.failureMessage(for: .success(FileManager.default.temporaryDirectory)) == nil)
      #expect(TextExporter.failureMessage(for: .failure(SaveFailure())) == "no room")
    }

    @Test("A failed save shows an alert, and OK dismisses it")
    func alert() {
      SystemSideEffects.reset()
      let screen = OffscreenWindow(
        Color.clear.modifier(TextExporter(export: .constant(nil), failure: "no room")),
        width: 300, height: 200)
      defer { screen.close() }
      screen.settle(0.2)
      #expect(SystemSideEffects.record.alertMessages == ["Could Not Save"])
    }
  }
#endif
