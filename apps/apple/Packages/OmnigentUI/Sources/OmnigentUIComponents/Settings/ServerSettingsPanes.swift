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
  /// The last failed change, shown in the token sheet when Connect fails.
  var errorMessage: String?
  @State private var tokenFor: MCPServiceRow?
  @State private var token = ""
  @State private var results: [String: String] = [:]
  @State private var isConnecting = false
  @State private var connectFailed = false

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
          .settingsRowButton()
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
        Section {
          SecureField("Personal access token", text: $token)
            .onChange(of: token) { if connectFailed { connectFailed = false } }
        } header: {
          Text("Connect \(service.name)")
        } footer: {
          // The failure shows here, beside the token, not behind the sheet.
          if connectFailed {
            Label(
              errorMessage ?? "The token was not accepted.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(Theme.failure)
            .accessibilityIdentifier("mcp-token-error")
          }
        }
        HStack {
          if isConnecting { ProgressView().controlSize(.small) }
          Spacer()
          Button("Cancel", role: .cancel) { close() }
          Button("Connect") { connect(service) }
            .keyboardShortcut(.defaultAction)
            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
        }
      }
      .formStyle(.grouped)
      .settingsSheetFrame(width: 420)
    }
  }

  private func detail(_ service: MCPServiceRow) -> String {
    let status = service.isConnected ? "Connected" : "Not connected"
    let tools = service.tools.isEmpty ? "" : " \u{00B7} \(service.tools.count) tools"
    return service.detail.isEmpty ? status + tools : "\(service.detail) \u{00B7} \(status)\(tools)"
  }

  private func connect(_ service: MCPServiceRow) {
    isConnecting = true
    connectFailed = false
    Task {
      let connected = await actions.connectMCP?(service, token) == true
      isConnecting = false
      if connected { close() } else { connectFailed = true }
    }
  }

  private func close() {
    tokenFor = nil
    token = ""
    connectFailed = false
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

/// Git: worktree defaults for new sessions on this device.
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
      Text("Saved on this \(SettingsDevice.name).")
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
  @State private var mode = ImportMode.recent
  @State private var sessionID = ""
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
        Picker("Import", selection: $mode) {
          ForEach(ImportMode.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: mode) { if mode == .session, source == "all" { source = "claude" } }
        .accessibilityIdentifier("settings.import.mode")
        Picker("Harness", selection: $source) {
          ForEach(sources.filter { mode == .recent || $0.id != "all" }) {
            Text($0.title).tag($0.id)
          }
        }
        switch mode {
        case .recent:
          Picker("Most recent", selection: $limit) {
            ForEach(Self.limits, id: \.self) { Text("\($0) sessions").tag($0) }
          }
        case .session:
          TextField("Session ID", text: $sessionID, prompt: Text("Enter a session ID"))
            .autocorrectionDisabled()
            .onSubmit { if canImport { Task { await runImport() } } }
            .accessibilityIdentifier("settings.import.session-id")
        }
        HStack {
          if let result { Text(result).foregroundStyle(.secondary).textSelection(.enabled) }
          Spacer()
          if isImporting { ProgressView().controlSize(.small) }
          Button("Import") { Task { await runImport() } }
            .disabled(!canImport)
        }
      }
    } header: {
      Text("Import from a machine")
    } footer: {
      Text(
        mode == .recent
          ? "Sessions already imported are skipped."
          : "The harness's own id for the session, as its CLI shows it.")
    }
    .onAppear { if host == nil { host = hosts.first?.id } }
    .onChange(of: hosts) { if host == nil { host = hosts.first?.id } }
  }

  private var canImport: Bool {
    host != nil && !isImporting && actions.importSessions != nil
      && (mode == .recent || !sessionID.trimmingCharacters(in: .whitespaces).isEmpty)
  }

  private func runImport() async {
    guard let host else { return }
    isImporting = true
    let exact = mode == .session ? sessionID.trimmingCharacters(in: .whitespaces) : nil
    result = await actions.importSessions?(host, source, limit, exact)
    isImporting = false
  }
}

/// Import the most recent sessions, or one by its harness id.
enum ImportMode: String, CaseIterable, Identifiable {
  /// The most recent sessions.
  case recent
  /// One session by id.
  case session

  var id: Self { self }

  var title: String {
    switch self {
    case .recent: "Recent sessions"
    case .session: "Session by ID"
    }
  }
}
