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
@main
struct OmnigentPlaygroundApp: App {
  #if os(macOS)
    @NSApplicationDelegateAdaptor(PlaygroundAppDelegate.self) private var appDelegate
  #endif
  @State private var model = Self.initialModel()

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
      PlaygroundView(model: model, slots: PlaygroundWorkspace.slots)
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
      }
    }
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
