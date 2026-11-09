import OmnigentWorkspaceUI
public import SwiftUI
import UniformTypeIdentifiers

/// Settings › Appearance › Settings data: Export, Import and Reset to defaults, in the web's
/// settings file format (``SettingsPortability``).
public struct SettingsDataSection: View {
  @State private var flow: SettingsDataFlow
  @State private var confirmingReset = false

  /// Creates the section.
  /// - Parameter theme: The live appearance, reloaded after an import or reset.
  public init(theme: ThemePreferences) {
    self.init(flow: SettingsDataFlow(theme: theme))
  }

  init(flow: SettingsDataFlow) {
    _flow = State(initialValue: flow)
  }

  /// The section.
  public var body: some View {
    @Bindable var flow = flow
    Section {
      #if os(iOS)
        // One row per action: a touch row fires every plain button it holds.
        message
        buttons
      #else
        HStack {
          message
          Spacer()
          buttons
        }
      #endif
    } header: {
      Text("Settings data")
    } footer: {
      Text("Settings files move between this app and Omnigent on the web.")
    }
    .fileExporter(
      isPresented: $flow.isExporting, document: flow.exporting, contentType: .json,
      defaultFilename: SettingsPortability.fileName, onCompletion: flow.finishExport
    )
    .fileImporter(
      isPresented: $flow.isImporting, allowedContentTypes: [.json],
      onCompletion: flow.finishImport
    )
    .confirmationDialog("Reset appearance?", isPresented: $confirmingReset) {
      Button("Reset", role: .destructive, action: flow.resetAppearance)
    } message: {
      Text("This will reset every appearance choice back to its default.")
    }
  }

  @ViewBuilder private var message: some View {
    if let failure = flow.failure {
      Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.failure)
    } else if let status = flow.status {
      Text(status).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var buttons: some View {
    Button("Export\u{2026}", action: flow.beginExport)
      .accessibilityIdentifier("settings.data.export")
    Button("Import\u{2026}") { flow.isImporting = true }
      .accessibilityIdentifier("settings.data.import")
    Button("Reset to Defaults\u{2026}") { confirmingReset = true }
      .accessibilityIdentifier("settings.data.reset")
  }

  /// What reading a settings file did, in the words the section shows.
  enum ImportResult: Equatable {
    case imported(String)
    case failed(String)
  }

  /// Applies a settings file to the store.
  static func importSettings(
    from url: URL, to defaults: UserDefaults = .standard
  ) -> ImportResult {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let settings = try SettingsPortability.settings(in: Data(contentsOf: url))
      let count = SettingsPortability.apply(settings, to: defaults)
      return .imported("Imported \(count) setting\(count == 1 ? "" : "s").")
    } catch let error as SettingsPortability.ImportError {
      return .failed(error.description)
    } catch {
      return .failed("Could not read the file: \(error.localizedDescription)")
    }
  }

}

/// What the section's panels start and finish: their results arrive here, so what each one does
/// doesn't depend on a panel being on screen.
@MainActor
@Observable
final class SettingsDataFlow {
  /// The file the save panel is writing; the panel shows while one is set.
  private(set) var exporting: SettingsFile?
  /// The open panel shows.
  var isImporting = false
  /// What the last action did.
  private(set) var status: String?
  /// Why the last action failed.
  private(set) var failure: String?

  @ObservationIgnored private let theme: ThemePreferences
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let makeExport: () throws -> Data

  /// Creates the flow.
  /// - Parameters:
  ///   - theme: The live appearance, reloaded after an import or reset.
  ///   - defaults: The store settings move through.
  ///   - makeExport: Writes the settings file; the store's export unless a caller replaces it.
  init(
    theme: ThemePreferences, defaults: UserDefaults = .standard,
    makeExport: (() throws -> Data)? = nil
  ) {
    self.theme = theme
    self.defaults = defaults
    self.makeExport = makeExport ?? { try SettingsPortability.export(defaults) }
  }

  /// The save panel shows; its closing forgets the file.
  var isExporting: Bool {
    get { exporting != nil }
    set { if !newValue { exporting = nil } }
  }

  func beginExport() {
    do {
      exporting = SettingsFile(data: try makeExport())
    } catch {
      show(failure: "Could not export: \(error.localizedDescription)")
    }
  }

  func finishExport(_ result: Result<URL, any Error>) {
    switch result {
    case .success: show(status: "Settings exported.")
    case .failure(let error): show(failure: "Could not export: \(error.localizedDescription)")
    }
  }

  func finishImport(_ result: Result<URL, any Error>) {
    switch result {
    case .success(let url): importFile(url)
    case .failure(let error): show(failure: "Could not open: \(error.localizedDescription)")
    }
  }

  func resetAppearance() {
    SettingsPortability.resetAppearance(defaults)
    reloadLivePreferences()
    show(status: "Appearance reset.")
  }

  private func importFile(_ url: URL) {
    switch SettingsDataSection.importSettings(from: url, to: defaults) {
    case .imported(let message):
      reloadLivePreferences()
      show(status: message)
    case .failed(let message):
      show(failure: message)
    }
  }

  /// The preferences held in memory; `@AppStorage` ones follow the store by themselves.
  private func reloadLivePreferences() {
    theme.reload(from: defaults)
    CodeTypography.shared.reload()
  }

  private func show(status: String? = nil, failure: String? = nil) {
    self.status = status
    self.failure = failure
  }
}

/// A settings file for the save panel.
struct SettingsFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  let data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard configuration.file.isRegularFile, let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
