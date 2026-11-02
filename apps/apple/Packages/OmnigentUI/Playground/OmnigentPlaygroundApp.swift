import OmnigentRemoteBrowser
import OmnigentTerminalUI
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI

#if os(macOS)
  import AppKit
#endif

/// The component playground: the full Omnigent layout with sample data in a real window, with the
/// scenario, theme and appearance in the Playground menu (scenarios on Command-1 through
/// Command-9).
///
/// Run with `swift run OmnigentPlayground`. Set `OMNIGENT_PLAYGROUND_THEME=<id>` and
/// `OMNIGENT_PLAYGROUND_APPEARANCE=light|dark` to start themed. Set `OMNIGENT_PLAYGROUND_SNAPSHOT=<file.png>` to write
/// a screenshot of the window once it has drawn, and `OMNIGENT_PLAYGROUND_SCENARIO=<name>` to
/// start in a scenario (for example `approvals`). Set `OMNIGENT_PLAYGROUND_INSPECTOR=<tab>` (for
/// example `terminals`) to open the right panel on that tab.
///
/// `--gallery` opens the component gallery (also Command-Shift-G), and
/// `--export-gallery <dir>` writes every gallery entry to PNGs and quits; see
/// `GalleryLaunchOptions` and `docs/gallery.md`.
@main
struct OmnigentPlaygroundApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(PlaygroundAppDelegate.self) private var appDelegate
  #endif
  @State private var model = Self.initialModel()
  private var gallery: GalleryLaunchOptions { Self.gallery }
  /// Parsed once: the delegate starts an export before any window exists.
  static let gallery = galleryOptions()

  /// The gallery's launch options; a bad option ends the process with its message.
  private static func galleryOptions() -> GalleryLaunchOptions {
    do {
      return try GalleryLaunchOptions(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment)
    } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(2)
    }
  }

  private static func initialModel() -> PlaygroundModel {
    let environment = ProcessInfo.processInfo.environment
    let model = PlaygroundModel(
      scenario: environment["OMNIGENT_PLAYGROUND_SCENARIO"]
        .flatMap(PlaygroundScenario.init(rawValue:)) ?? .streaming)
    if let theme = environment["OMNIGENT_PLAYGROUND_THEME"] { model.preferences.paletteID = theme }
    if let appearance = environment["OMNIGENT_PLAYGROUND_APPEARANCE"]
      .flatMap(AppearancePreference.init(rawValue:))
    {
      model.preferences.mode = appearance
    }
    if let tab = environment["OMNIGENT_PLAYGROUND_INSPECTOR"].flatMap(InspectorTab.init(rawValue:))
    {
      model.inspectorTab = tab
      model.showsInspector = true
    }
    return model
  }

  var body: some Scene {
    WindowGroup("Omnigent Playground") {
      Group {
        if gallery.exports {
          Text("Exporting the gallery\u{2026}").padding(24)
        } else if gallery.showsGallery {
          GalleryCatalogView(options: gallery)
        } else {
          PlaygroundView(model: model, slots: PlaygroundWorkspace.slots)
        }
      }
      // The tabs scenario and the gallery's tab flow show a remote browser on the fixture host.
      .environment(\.remoteBrowserPreview, AnyView(RemoteBrowserFixtureTab()))
      #if os(macOS)
        .frame(minWidth: 900, minHeight: 600)
        .task { await PlaygroundSnapshot.writeIfRequested() }
      #endif
    }
    #if os(macOS)
      .defaultSize(width: 1_440, height: 900)
    #endif
    .commands {
      OmnigentSessionCommands()
      // The playground's own controls live here, so the window's toolbar row matches the app.
      CommandMenu("Playground") {
        OpenGalleryButton()
        Divider()
        Section("Scenario") {
          let scenarios = Array(PlaygroundScenario.allCases.enumerated())
          ForEach(scenarios, id: \.element) { index, scenario in
            if index < 9 {
              Button(scenario.title) { model.scenario = scenario }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            } else {
              Button(scenario.title) { model.scenario = scenario }
            }
          }
        }
        Divider()
        Picker("Theme", selection: Bindable(model.preferences).paletteID) {
          ForEach(model.preferences.themes) { theme in Text(theme.name).tag(theme.id) }
        }
        Picker("Appearance", selection: Bindable(model.preferences).mode) {
          ForEach(AppearancePreference.allCases) { preference in
            Text(preference.title).tag(preference)
          }
        }
        Picker("Transcript Style", selection: Bindable(model.preferences.transcript).style) {
          ForEach(TranscriptStyle.allCases) { Text($0.title).tag($0) }
        }
        Picker(
          "Output Rendering", selection: Bindable(model.preferences.transcript).outputRendering
        ) {
          ForEach(OutputRendering.allCases) { Text($0.title).tag($0) }
        }
      }
    }
    #if os(macOS)
      Window("Gallery", id: OpenGalleryButton.windowID) {
        GalleryCatalogView()
      }
      .defaultSize(width: 1_500, height: 960)
    #endif
  }
}

/// Opens the component gallery in its own window.
struct OpenGalleryButton: View {
  static let windowID = "gallery"
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Open Gallery") { openWindow(id: Self.windowID) }
      .keyboardShortcut("g", modifiers: [.command, .shift])
  }
}

/// Writes the gallery to PNGs, prints where, and quits: 0 on success, 1 on failure. It runs
/// from the app delegate, so it does not wait for a window (launch arguments with values can
/// keep SwiftUI from opening one).
enum GalleryExportRunner {
  static func run(_ options: GalleryLaunchOptions) async -> Never {
    do {
      let report = try await GallerySnapshotExport.run(options) { done, total in
        if done.isMultiple(of: 50) { write("Rendered \(done) of \(total)\n") }
      }
      write("Wrote \(report.images.count) images to \(report.directory.path)\n")
      write("Contact sheet: \(report.index.path)\nManifest: \(report.manifest.path)\n")
      exit(0)
    } catch {
      FileHandle.standardError.write(Data("Gallery export failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }
}

/// Real Files and Changes content from `OmnigentWorkspaceUI`, on its sample data source, and the
/// real terminal list and surface from `OmnigentTerminalUI`, on local echo shells.
enum PlaygroundWorkspace {
  static let browser = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())

  static var slots: WorkspaceSlots {
    WorkspaceSlots(
      files: AnyView(
        FileTreeView(model: browser.tree, source: browser.source, actions: .none)
          .task { await WorkspaceGallery.prepare(browser.tree) }),
      changes: AnyView(
        ChangedFilesList(model: browser.changes, source: browser.source, actions: .none) { _ in }
          .task { await browser.changes.reload() }),
      terminals: AnyView(PlaygroundTerminals()))
  }
}

/// The Terminals tab as the app lays it out (the list above the attached surface), over sample
/// rows and a local echo shell. Nothing here talks to a server.
struct PlaygroundTerminals: View {
  @State private var items = [
    TerminalListItem(
      id: "terminal_claude_main", title: "claude \u{00B7} main", status: .active,
      isAgentTerminal: true),
    TerminalListItem(
      id: "terminal_zsh_u-4f2k9q", title: "zsh \u{00B7} u-4f2k9q", status: .idle,
      isAgentTerminal: false),
    TerminalListItem(
      id: "terminal_bash_u-0c1d2e", title: "bash \u{00B7} u-0c1d2e", status: .exited,
      isAgentTerminal: false),
  ]
  @State private var selection: TerminalListItem.ID? = "terminal_zsh_u-4f2k9q"

  var body: some View {
    VStack(spacing: 0) {
      TerminalListView(
        items: items, shellChoices: ["zsh", "bash"], canEdit: true, errorMessage: nil,
        selection: $selection,
        onCreate: { shell in
          let item = TerminalListItem(
            id: "terminal_\(shell)_\(items.count)", title: "\(shell) \u{00B7} new", status: .idle,
            isAgentTerminal: false)
          items.append(item)
          selection = item.id
        },
        onClose: { id in
          items.removeAll { $0.id == id }
          if selection == id { selection = nil }
        }
      )
      .listStyle(.plain)
      .frame(minHeight: 96, idealHeight: 160, maxHeight: selection == nil ? .infinity : 200)
      if let selection, let item = items.first(where: { $0.id == selection }) {
        Divider()
        SessionTerminalView(
          connection: EchoTerminalConnection(
            prompt: "\(item.title.split(separator: " ").first ?? "sh")$ ",
            banner: "Attached to \(item.title)")
        )
        .id(selection)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }
}

#if os(macOS)
  /// A command-line executable has no bundle, so it must ask to be a regular, frontmost app.
  final class PlaygroundAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
      if OmnigentPlaygroundApp.gallery.exports {
        Task { await GalleryExportRunner.run(OmnigentPlaygroundApp.gallery) }
        return
      }
      NSApplication.shared.setActivationPolicy(.regular)
      NSApplication.shared.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
      true
    }
  }

  /// Writes the key window to `OMNIGENT_PLAYGROUND_SNAPSHOT` after it has drawn.
  enum PlaygroundSnapshot {
    enum SnapshotError: Error, CustomStringConvertible {
      case noWindow
      case captureFailed(status: Int32)

      var description: String {
        switch self {
        case .noWindow: "The playground has no window to capture."
        case .captureFailed(let status): "screencapture exited with status \(status)."
        }
      }
    }

    static func writeIfRequested() async {
      guard let path = ProcessInfo.processInfo.environment["OMNIGENT_PLAYGROUND_SNAPSHOT"] else {
        return
      }
      do {
        try await Task.sleep(for: .seconds(2))
        try write(to: URL(filePath: path))
        print("Wrote \(path)")
      } catch {
        // Report and keep running: the playground itself is still usable.
        FileHandle.standardError.write(Data("Snapshot failed: \(error)\n".utf8))
      }
    }

    /// Captures the whole window, chrome and vibrancy included, with `screencapture`. Needs the
    /// Screen Recording permission for the launching terminal.
    private static func write(to url: URL) throws {
      guard let window = NSApplication.shared.windows.first(where: \.isVisible) else {
        throw SnapshotError.noWindow
      }
      let process = Process()
      process.executableURL = URL(filePath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
      try process.run()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw SnapshotError.captureFailed(status: process.terminationStatus)
      }
    }
  }
#endif
