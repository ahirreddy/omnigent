public import SwiftUI
import UniformTypeIdentifiers

/// Settings › Appearance › Settings data: Export, Import and Reset to defaults, in the web's
/// settings file format (``SettingsPortability``).
public struct SettingsDataSection: View {
  private let theme: ThemePreferences
  @State private var exporting: SettingsFile?
  @State private var importing = false
  @State private var confirmingReset = false
  @State private var status: String?
  @State private var failure: String?

  /// Creates the section.
  /// - Parameter theme: The live appearance, reloaded after an import or reset.
  public init(theme: ThemePreferences) {
    self.theme = theme
  }

  /// The section.
  public var body: some View {
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
      isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
      document: exporting, contentType: .json, defaultFilename: SettingsPortability.fileName
    ) { result in
      switch result {
      case .success: show(status: "Settings exported.")
      case .failure(let error): show(failure: "Could not export: \(error.localizedDescription)")
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
      switch result {
      case .success(let url): importFile(url)
      case .failure(let error): show(failure: "Could not open: \(error.localizedDescription)")
      }
    }
    .confirmationDialog("Reset appearance?", isPresented: $confirmingReset) {
      Button("Reset", role: .destructive) {
        SettingsPortability.resetAppearance()
        theme.reload()
        show(status: "Appearance reset.")
      }
    } message: {
      Text("This will reset every appearance choice back to its default.")
    }
  }

  @ViewBuilder private var message: some View {
    if let failure {
      Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.failure)
    } else if let status {
      Text(status).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder private var buttons: some View {
    Button("Export\u{2026}", action: export)
      .accessibilityIdentifier("settings.data.export")
    Button("Import\u{2026}") { importing = true }
      .accessibilityIdentifier("settings.data.import")
    Button("Reset to Defaults\u{2026}") { confirmingReset = true }
      .accessibilityIdentifier("settings.data.reset")
  }

  private func export() {
    do {
      exporting = SettingsFile(data: try SettingsPortability.export())
    } catch {
      show(failure: "Could not export: \(error.localizedDescription)")
    }
  }

  private func importFile(_ url: URL) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    do {
      let settings = try SettingsPortability.settings(in: Data(contentsOf: url))
      let count = SettingsPortability.apply(settings)
      theme.reload()
      show(status: "Imported \(count) setting\(count == 1 ? "" : "s").")
    } catch let error as SettingsPortability.ImportError {
      show(failure: error.description)
    } catch {
      show(failure: "Could not read the file: \(error.localizedDescription)")
    }
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
    guard let data = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = data
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

extension ThemePreferences {
  /// Rereads the stored appearance after its keys changed underneath it (an import or reset),
  /// assigning only what changed.
  /// - Parameter defaults: The store the preferences were loaded from.
  public func reload(from defaults: UserDefaults = .standard) {
    let stored = ThemePreferences(defaults: defaults)
    if mode != stored.mode { mode = stored.mode }
    if paletteID != stored.paletteID { paletteID = stored.paletteID }
    if custom != stored.custom { custom = stored.custom }
    if terminal != stored.terminal { terminal = stored.terminal }
  }
}
