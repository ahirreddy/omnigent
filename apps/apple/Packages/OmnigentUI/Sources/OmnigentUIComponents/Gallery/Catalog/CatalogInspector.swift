import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The gallery's global controls: appearance, palette, device, accessibility and export.
struct CatalogInspector: View {
  @Bindable var settings: CatalogSettings
  let current: CatalogEntry?
  let results: [CatalogEntry]
  @State private var exportScope: ExportScope = .current
  @State private var export = CatalogExportStatus.idle

  enum ExportScope: String, CaseIterable, Identifiable {
    case current
    case results
    case everything

    var id: Self { self }

    var title: String {
      switch self {
      case .current: "This entry"
      case .results: "Search results"
      case .everything: "Everything"
      }
    }
  }

  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Appearance", selection: $settings.appearance) {
          ForEach(CatalogAppearance.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("gallery-appearance")
        Picker("Theme", selection: Bindable(settings.preferences).paletteID) {
          ForEach(settings.preferences.themes) { theme in
            HStack {
              ThemeSwatch(theme: theme)
              Text(theme.name)
            }
            .tag(theme.id)
          }
        }
        .accessibilityIdentifier("gallery-theme")
      }
      Section("Device") {
        Picker("Device", selection: $settings.device) {
          ForEach(CatalogDevice.allCases) { device in
            let size = CatalogScreen(device).size
            Label(
              "\(device.title)  \(Int(size.width))\u{00D7}\(Int(size.height))",
              systemImage: device.systemImage
            )
            .tag(device)
          }
        }
        .accessibilityIdentifier("gallery-device")
        Toggle("Device frame", isOn: $settings.showsFrame)
          .disabled(settings.device == .mac)
          .accessibilityIdentifier("gallery-device-frame")
        Toggle("Landscape", isOn: $settings.isLandscape)
          .disabled(!settings.device.canRotate)
          .accessibilityIdentifier("gallery-rotate")
        Toggle("Unfolded", isOn: $settings.isUnfolded)
          .disabled(!settings.device.canFold)
          .accessibilityIdentifier("gallery-unfold")
        Toggle("Fit pages to the window", isOn: $settings.fitsPages)
        Toggle("Show every component state", isOn: $settings.showsAllStates)
      }
      Section("Accessibility") {
        Picker("Text size", selection: $settings.dynamicType) {
          ForEach(DynamicTypeSize.allCases, id: \.self) { size in
            Text(CatalogTraits.name(size).uppercased()).tag(size)
          }
        }
        .accessibilityIdentifier("gallery-dynamic-type")
        Toggle("Increase contrast", isOn: $settings.increaseContrast)
          .accessibilityIdentifier("gallery-contrast")
        Toggle("Reduce motion", isOn: $settings.reduceMotion)
          .accessibilityIdentifier("gallery-reduce-motion")
        Toggle("Right to left", isOn: $settings.rightToLeft)
          .accessibilityIdentifier("gallery-rtl")
      }
      Section {
        Picker("Export", selection: $exportScope) {
          ForEach(ExportScope.allCases) { Text($0.title).tag($0) }
        }
        Button("Export PNGs\u{2026}", systemImage: "square.and.arrow.down.on.square") {
          chooseDirectory()
        }
        .disabled(export.isRunning || entries.isEmpty)
        .accessibilityIdentifier("gallery-export")
        CatalogExportStatusView(status: export)
      } header: {
        Text("Snapshots")
      } footer: {
        Text(
          "Light and dark at the current theme, accessibility and frame settings; pages on the "
            + "Mac and the chosen device. Writes index.html and manifest.json beside the images.")
      }
    }
    .formStyle(.grouped)
  }

  private var entries: [CatalogEntry] {
    switch exportScope {
    case .current: current.map { [$0] } ?? []
    case .results: results
    case .everything: GalleryCatalog.entries
    }
  }

  private func chooseDirectory() {
    #if os(macOS)
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.canCreateDirectories = true
      panel.prompt = "Export"
      panel.message = "Choose a folder for the gallery PNGs."
      guard panel.runModal() == .OK, let directory = panel.url else { return }
      run(to: directory)
    #else
      do {
        let documents = try FileManager.default.url(
          for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        run(to: documents.appending(path: "GallerySnapshots", directoryHint: .isDirectory))
      } catch {
        export = .failed(String(describing: error))
      }
    #endif
  }

  private func run(to directory: URL) {
    let job = CatalogExportJob(
      entries: entries, directory: directory, schemes: [.light, .dark],
      screens: [CatalogScreen(.mac), settings.screen].reduce(into: []) { screens, screen in
        if !screens.contains(screen) { screens.append(screen) }
      },
      componentScreen: settings.screen, framed: settings.showsFrame,
      preferences: settings.preferences, dynamicType: settings.dynamicType,
      increaseContrast: settings.increaseContrast, reduceMotion: settings.reduceMotion,
      rightToLeft: settings.rightToLeft)
    export = .running(done: 0, total: CatalogExporter.plan(job).count)
    Task {
      do {
        let report = try await CatalogExporter.run(job) { done, total in
          export = .running(done: done, total: total)
        }
        export = .finished(report)
      } catch {
        export = .failed(String(describing: error))
      }
    }
  }
}

/// Where the inspector's export stands.
enum CatalogExportStatus {
  case idle
  case running(done: Int, total: Int)
  case finished(GalleryExportReport)
  case failed(String)

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }
}

private struct CatalogExportStatusView: View {
  let status: CatalogExportStatus

  var body: some View {
    switch status {
    case .idle:
      EmptyView()
    case .running(let done, let total):
      ProgressView(value: Double(done), total: Double(max(total, 1))) {
        Text("Rendering \(done) of \(total)")
      }
    case .finished(let report):
      VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
        Label("Wrote \(report.images.count) images", systemImage: "checkmark.circle")
        Text(report.directory.path).font(.caption.monospaced()).textSelection(.enabled)
        #if os(macOS)
          Button("Open the Contact Sheet") { NSWorkspace.shared.open(report.index) }
        #endif
      }
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(Theme.failure)
        .textSelection(.enabled)
    }
  }
}

#if os(macOS)
  /// Opens a state in its own titled window, where its toolbar and sheets work as in the app.
  enum CatalogWindows {
    private static var open: [NSWindow] = []

    static func open(
      title: String, state: CatalogState, context: CatalogContext, traits: CatalogTraits,
      layout: CatalogLayout
    ) {
      let content = state.make(context)
        .themeCanvas()
        .catalogTraits(traits)
        .frame(minWidth: 320, minHeight: 240)
      let controller = NSHostingController(rootView: AnyView(content))
      controller.sceneBridgingOptions = .all
      let window = NSWindow(contentViewController: controller)
      window.title = title
      window.styleMask.insert(.fullSizeContentView)
      window.appearance = CatalogAppearanceName.appearance(for: traits)
      window.isReleasedWhenClosed = false
      window.setContentSize(CGSize(width: layout.width, height: layout.height ?? 720))
      window.center()
      open.append(window)
      NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: .main
      ) { notification in
        let closing = notification.object as? NSWindow
        MainActor.assumeIsolated { open.removeAll { $0 === closing } }
      }
      window.makeKeyAndOrderFront(nil)
    }
  }
#endif
