import AppKit
public import SwiftUI
import UniformTypeIdentifiers

/// The Local Server settings, as shown on the Settings window's Local Server tab, for apps that
/// build their own Settings window.
public struct LocalServerSettingsView: View {
  private let desktop: DesktopController

  /// Creates the view.
  /// - Parameter desktop: The shell services.
  public init(desktop: DesktopController) {
    self.desktop = desktop
  }

  /// The form.
  public var body: some View {
    LocalServerSettingsTab(
      manager: desktop.localServer, preferences: desktop.localServerPreferences)
  }
}

/// Settings > Local Server: status, the CLI, startup options, the menu bar extra and logs. The
/// App Store edition shows only the explanation of why it cannot run a server.
struct LocalServerSettingsTab: View {
  let manager: LocalServerManager
  @Bindable var preferences: LocalServerPreferences
  @Environment(\.openWindow) private var openWindow
  @State private var message: String?

  var body: some View {
    Form {
      if case .unavailable(let reason) = manager.capability {
        Section {
          Label(reason.explanation, systemImage: "lock.shield")
            .fixedSize(horizontal: false, vertical: true)
        }
        menuBarSection
      } else {
        statusSection
        cliSection
        startupSection
        menuBarSection
        logsSection
      }
    }
    .formStyle(.grouped)
  }

  private var statusSection: some View {
    Section {
      LocalServiceRow(
        title: "Server", tone: manager.server.tone, summary: manager.server.summary,
        startTitle: "Start", canStart: manager.server.canStart,
        canStop: manager.server.canStop, start: { LocalServerActions.startServer(manager) },
        stop: { LocalServerActions.stopServer(manager) })
      if let ownership = manager.server.ownership {
        LabeledContent("Started by", value: ownership.label)
      }
      if let version = manager.server.endpoint?.manifest?.serverVersion {
        LabeledContent("Server version", value: version)
      }
      LocalServiceRow(
        title: "Host", tone: manager.host.tone, summary: manager.host.summary,
        startTitle: "Start\u{2026}", canStart: manager.host.canStart,
        canStop: manager.host.canStop,
        start: { LocalServerActions.startHost(manager, fallback: nil) },
        stop: { LocalServerActions.stopHost(manager) })
    } header: {
      Text("This Mac")
    } footer: {
      Text(
        "Hosting lets a server run agents on this Mac. Omnigent asks each time and never hosts "
          + "on its own.")
    }
  }

  private var cliSection: some View {
    Section {
      LabeledContent("Command") {
        Text(cliDescription)
          .foregroundStyle(manager.cli.resolution == nil ? .red : .primary)
          .textSelection(.enabled)
          .multilineTextAlignment(.trailing)
      }
      if case .missing(let error) = manager.cli {
        Text(error.message).font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Button("Choose\u{2026}") { chooseCLI() }
        Button("Use Automatic") {
          preferences.cliPath = nil
          Task { await manager.refreshCLI() }
        }
        .disabled(preferences.cliPath == nil)
        Spacer()
        Button("Refresh") { Task { await manager.refreshCLI() } }
      }
    } header: {
      Text("Command-Line Tool")
    } footer: {
      Text(
        "Automatic looks on your login shell's PATH, then in ~/.local/bin (uv tool, pipx), "
          + "Homebrew and ~/.cargo/bin.")
    }
    .task { if manager.cli == .notChecked { await manager.refreshCLI() } }
  }

  private var cliDescription: String {
    switch manager.cli {
    case .notChecked, .checking: "Looking\u{2026}"
    case .found(let resolution): resolution.command.displayString
    case .missing: "Not found"
    }
  }

  private var startupSection: some View {
    Section {
      Toggle("Start the server when Omnigent opens", isOn: $preferences.startOnLaunch)
      Toggle("Restart the server or host after a crash", isOn: $preferences.restartOnCrash)
      Toggle("Choose port automatically", isOn: automaticPort)
      if let port = preferences.port {
        TextField("Port", value: fixedPort(default: port), format: .number.grouping(.never))
      }
      LabeledContent("Data directory") {
        Text(manager.dataDirectory.path).textSelection(.enabled).truncationMode(.middle)
      }
      HStack {
        Button("Choose\u{2026}") { chooseDataDirectory() }
        Button("Use Default") { preferences.dataDirectory = nil }
          .disabled(preferences.dataDirectory == nil)
      }
    } header: {
      Text("Server")
    } footer: {
      Text(
        "An automatic port uses 6767 when it is free and is shared with `omnigent run` in "
          + "Terminal. A fixed port runs a separate server. Changes apply the next time the "
          + "server starts.")
    }
  }

  private var menuBarSection: some View {
    Section {
      Toggle("Show Omnigent in the menu bar", isOn: $preferences.showsMenuBarExtra)
    } header: {
      Text("Menu Bar")
    }
  }

  private var logsSection: some View {
    Section {
      HStack {
        Button("Show Server Logs") { openWindow(id: LocalServerLogsWindow.id) }
        Button("Open Log Folder") { message = LocalServerActions.revealLogFolder(manager) }
      }
      if let message {
        Text(message).font(.callout).foregroundStyle(.secondary)
      }
    } header: {
      Text("Logs")
    }
  }

  private var automaticPort: Binding<Bool> {
    Binding(
      get: { preferences.port == nil },
      set: { preferences.port = $0 ? nil : 6767 })
  }

  private func fixedPort(default port: Int) -> Binding<Int> {
    Binding(
      get: { preferences.port ?? port },
      set: { preferences.port = (1...65_535).contains($0) ? $0 : preferences.port })
  }

  private func chooseCLI() {
    let panel = NSOpenPanel()
    panel.message = "Choose the omnigent command-line tool."
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = true
    panel.allowedContentTypes = [.unixExecutable, .item]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    preferences.cliPath = url.path
    Task { await manager.refreshCLI() }
  }

  private func chooseDataDirectory() {
    let panel = NSOpenPanel()
    panel.message = "Choose the directory for the server's database, artifacts and logs."
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    preferences.dataDirectory = url.path
  }
}
