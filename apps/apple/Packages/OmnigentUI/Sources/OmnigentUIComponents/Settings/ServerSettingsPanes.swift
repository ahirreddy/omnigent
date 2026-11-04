public import SwiftUI

/// Device-local Git preferences under the web's keys; the new-session form reads them.
public enum GitPreferences {
  /// Start new sessions in a fresh random worktree (`true`/`false`).
  public static let alwaysUseWorktreeKey = "omnigent:always-use-worktree"
  /// The base branch pre-filled for a new worktree branch.
  public static let defaultBaseBranchKey = "omnigent:default-base-branch"
  /// Remove a session's worktree when it is archived: `true`, `false`, or unset to ask.
  public static let deleteWorktreesOnArchiveKey = "omnigent:delete-worktrees-on-archive"
}

/// Account: change the caller's password.
struct ChangePasswordPane: View {
  let actions: ServerSettingsActions
  @State private var current = ""
  @State private var new = ""
  @State private var confirmation = ""
  @State private var changed = false

  var body: some View {
    Section {
      SecureField("Current password", text: $current)
      SecureField("New password", text: $new)
      SecureField("Confirm new password", text: $confirmation)
      HStack {
        if changed {
          Label("Password changed", systemImage: "checkmark.circle").foregroundStyle(.secondary)
        } else if !confirmation.isEmpty, confirmation != new {
          Text("The new passwords don't match.").foregroundStyle(Theme.failure)
        }
        Spacer()
        Button("Change Password") {
          Task {
            changed = await actions.changePassword?(current, new) ?? false
            if changed { (current, new, confirmation) = ("", "", "") }
          }
        }
        .disabled(current.isEmpty || new.isEmpty || new != confirmation)
      }
    } header: {
      Text("Change password")
    } footer: {
      Text("Your other sessions and command-line sign-ins are signed out.")
    }
  }
}

/// MCP: the registry's services, with connect and disconnect for the caller's own account.
struct MCPPane: View {
  let services: [MCPServiceRow]
  let actions: ServerSettingsActions
  @State private var tokenFor: MCPServiceRow?
  @State private var token = ""
  @State private var results: [String: String] = [:]

  var body: some View {
    Section {
      if services.isEmpty { Text("No MCP services.").foregroundStyle(.secondary) }
      ForEach(services) { service in
        LabeledContent {
          HStack {
            if service.acceptsToken, !service.isConnected {
              Button("Connect\u{2026}") { tokenFor = service }
            }
            if service.connectsInBrowser {
              Button("Connect in Browser") { actions.openInBrowser?(.mcp) }
            }
            if service.isConnected {
              Button("Test") {
                Task { results[service.id] = await actions.testMCP?(service) }
              }
            }
            if service.canDisconnect {
              Button("Disconnect") { actions.disconnectMCP?(service) }
            }
          }
        } label: {
          Text(service.name)
          Text(results[service.id] ?? detail(service))
        }
      }
    } footer: {
      Text("Services agents can use with your accounts. Connected tools appear in new sessions.")
    }
    .sheet(item: $tokenFor) { service in
      Form {
        Section("Connect \(service.name)") {
          SecureField("Personal access token", text: $token)
        }
        HStack {
          Spacer()
          Button("Cancel", role: .cancel) { close() }
          Button("Connect") {
            Task { if await actions.connectMCP?(service, token) == true { close() } }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
      .formStyle(.grouped)
      .frame(width: 420)
    }
  }

  private func detail(_ service: MCPServiceRow) -> String {
    let status = service.isConnected ? "Connected" : "Not connected"
    let tools = service.tools.isEmpty ? "" : " \u{00B7} \(service.tools.count) tools"
    return service.detail.isEmpty ? status + tools : "\(service.detail) \u{00B7} \(status)\(tools)"
  }

  private func close() {
    tokenFor = nil
    token = ""
  }
}

/// Sandbox Integrations: provider accounts the server's sandboxes use for the caller.
struct IntegrationsPane: View {
  let connections: [ProviderConnectionRow]
  let actions: ServerSettingsActions

  var body: some View {
    Section {
      if connections.isEmpty { Text("No integrations.").foregroundStyle(.secondary) }
      ForEach(connections) { connection in
        LabeledContent {
          if connection.isConnected {
            Button("Disconnect") { actions.disconnectProvider?(connection) }
          } else {
            Button("Connect in Browser") { actions.openInBrowser?(.integrations) }
          }
        } label: {
          Text(connection.name)
          Text(connection.account.map { "Connected as \($0)" } ?? "Not connected")
        }
      }
    } footer: {
      Text(
        "Connecting signs in on the server's web page in your browser. Refresh this pane afterwards."
      )
    }
  }
}

/// Git: worktree defaults for new sessions on this Mac.
struct GitSettingsPane: View {
  let archiveWorktreeCleanup: Bool
  @AppStorage(GitPreferences.alwaysUseWorktreeKey) private var alwaysUseWorktree = false
  @AppStorage(GitPreferences.defaultBaseBranchKey) private var defaultBaseBranch = ""
  @AppStorage(GitPreferences.deleteWorktreesOnArchiveKey) private var deleteOnArchive = ""

  var body: some View {
    Section {
      Toggle(isOn: $alwaysUseWorktree) {
        Text("Always use a random worktree")
        Text(
          "Start new sessions in a fresh randomly named git worktree. A project's own setting overrides this."
        )
      }
      LabeledContent {
        TextField("Default base branch", text: $defaultBaseBranch, prompt: Text("e.g. main"))
          .labelsHidden()
          .frame(width: 180)
          .autocorrectionDisabled()
      } label: {
        Text("Default base branch")
        Text("Pre-filled as the base when you name a new worktree branch.")
      }
      if archiveWorktreeCleanup {
        Picker(selection: $deleteOnArchive) {
          Text("Ask each time").tag("")
          Text("Delete the worktree").tag("true")
          Text("Keep the worktree").tag("false")
        } label: {
          Text("When archiving a worktree session")
          Text("Deleting removes uncommitted changes. The branch is kept.")
        }
      }
    } header: {
      Text("Worktrees")
    } footer: {
      Text("Saved on this Mac.")
    }
  }
}

/// Import Sessions: pull a host's local harness sessions into the server.
struct ImportSessionsPane: View {
  let hosts: [SettingChoice]
  let sources: [SettingChoice]
  let actions: ServerSettingsActions
  @State private var host: String?
  @State private var source = "all"
  @State private var limit = 25
  @State private var result: String?
  @State private var isImporting = false

  private static let limits = [25, 50, 100, 200, 500, 1000]

  var body: some View {
    Section {
      if hosts.isEmpty {
        Text("No machine is online. Run omnigent host on the machine with your sessions.")
          .foregroundStyle(.secondary)
      } else {
        Picker("Machine", selection: $host) {
          ForEach(hosts) { Text($0.title).tag(Optional($0.id)) }
        }
        Picker("Harness", selection: $source) {
          ForEach(sources) { Text($0.title).tag($0.id) }
        }
        Picker("Most recent", selection: $limit) {
          ForEach(Self.limits, id: \.self) { Text("\($0) sessions").tag($0) }
        }
        HStack {
          if let result { Text(result).foregroundStyle(.secondary).textSelection(.enabled) }
          Spacer()
          if isImporting { ProgressView().controlSize(.small) }
          Button("Import") { Task { await runImport() } }
            .disabled(host == nil || isImporting || actions.importSessions == nil)
        }
      }
    } header: {
      Text("Import from a machine")
    } footer: {
      Text("Sessions already imported are skipped.")
    }
    .onAppear { if host == nil { host = hosts.first?.id } }
    .onChange(of: hosts) { if host == nil { host = hosts.first?.id } }
  }

  private func runImport() async {
    guard let host else { return }
    isImporting = true
    result = await actions.importSessions?(host, source, limit)
    isImporting = false
  }
}
