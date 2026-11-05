public import SwiftUI

/// Server settings as native panes for the Mac Settings window: a server picker, then the panes
/// the server and caller offer (Account, Harnesses, MCP, Integrations, Git, Import, the Admin
/// panes and Archived sessions). Each pane loads when shown.
public struct ServerSettingsView: View {
  private let state: ServerSettingsViewState
  @Binding private var selectedServer: String?
  private let actions: ServerSettingsActions
  private let hostedPane: (ServerSettingsPane) -> AnyView?
  private let selectedPane: Binding<ServerSettingsPane?>?
  @State private var localPane: ServerSettingsPane?

  /// Creates the settings.
  /// - Parameters:
  ///   - state: The selected server's settings.
  ///   - selectedServer: The server whose settings show.
  ///   - selectedPane: The shown pane, so the host can open one; the view keeps its own when
  ///     `nil`.
  ///   - actions: Loads and changes.
  ///   - hostedPane: A pane the host draws itself (for example Harnesses over the app's stores),
  ///     or `nil` for the built-in one.
  public init(
    state: ServerSettingsViewState, selectedServer: Binding<String?>,
    selectedPane: Binding<ServerSettingsPane?>? = nil, actions: ServerSettingsActions,
    hostedPane: @escaping (ServerSettingsPane) -> AnyView? = { _ in nil }
  ) {
    self.state = state
    _selectedServer = selectedServer
    self.selectedPane = selectedPane
    self.actions = actions
    self.hostedPane = hostedPane
  }

  private var pane: Binding<ServerSettingsPane?> { selectedPane ?? $localPane }

  private var shownPane: ServerSettingsPane? {
    pane.wrappedValue.flatMap { state.panes.contains($0) ? $0 : nil } ?? state.panes.first
  }

  /// The settings.
  public var body: some View {
    NavigationSplitView {
      List(selection: pane) {
        Section {
          ForEach(state.panes.filter { !$0.isAdmin && $0 != .archived }) { row($0) }
        }
        let admin = state.panes.filter(\.isAdmin)
        if !admin.isEmpty {
          Section("Admin") { ForEach(admin) { row($0) } }
        }
        if state.panes.contains(.archived) {
          Section { row(.archived) }
        }
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        Picker("Server", selection: $selectedServer) {
          ForEach(state.servers) { server in
            Text(server.name).tag(Optional(server.id))
          }
        }
        .labelsHidden()
        .padding(Theme.Spacing.medium)
        .accessibilityIdentifier("server-settings-picker")
      }
      .navigationSplitViewColumnWidth(min: 180, ideal: 200)
    } detail: {
      Form {
        if let error = state.errorMessage {
          Section {
            Label(error, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(Theme.failure)
              .textSelection(.enabled)
          }
        }
        if state.isLoading {
          ProgressView().frame(maxWidth: .infinity)
        }
        paneContent
      }
      .formStyle(.grouped)
      .disabled(state.isSaving)
      .navigationTitle(shownPane?.title ?? "Server Settings")
    }
    .frame(minWidth: 720, minHeight: 480)
    .task(id: LoadKey(server: selectedServer, pane: shownPane)) {
      if let shownPane { actions.load?(shownPane) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("server-settings")
  }

  private func row(_ pane: ServerSettingsPane) -> some View {
    Label(pane.title, systemImage: pane.systemImage).tag(pane)
  }

  @ViewBuilder private var paneContent: some View {
    if let shownPane, let hosted = hostedPane(shownPane) {
      hosted
    } else {
      builtInPane
    }
  }

  @ViewBuilder private var builtInPane: some View {
    switch shownPane {
    case .account: AccountSettingsPane(account: state.account, actions: actions)
    case .harnesses: harnesses
    case .customAgents: Text("Custom agents are not available here.").foregroundStyle(.secondary)
    case .mcp: MCPPane(services: state.mcpServices, actions: actions)
    case .integrations: IntegrationsPane(connections: state.connections, actions: actions)
    case .git: GitSettingsPane(archiveWorktreeCleanup: state.archiveWorktreeCleanup)
    case .importSessions:
      ImportSessionsPane(hosts: state.importHosts, sources: state.importSources, actions: actions)
    case .members: MembersPane(members: state.members, actions: actions)
    case .policies: PoliciesPane(policies: state.policies, actions: actions)
    case .sharing: SharingPane(sharing: state.sharing, actions: actions)
    case .archived:
      ArchivedSessionsPane(
        sessions: state.archived, info: state.archivedInfo, projects: state.archivedProjects,
        hasMore: state.hasMoreArchived, actions: actions)
    case nil: Text("Sign in to a server to see its settings.").foregroundStyle(.secondary)
    }
  }

  private var harnesses: some View {
    Section {
      ForEach(state.harnesses) { harness in
        Toggle(
          isOn: Binding(
            get: { harness.isEnabled }, set: { actions.setHarnessEnabled?(harness, $0) })
        ) {
          HStack(spacing: Theme.Spacing.small) {
            HarnessGlyph(harness: harness.harness, size: 18)
            VStack(alignment: .leading) {
              Text(harness.name)
              if let note = harness.note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
          }
        }
        .disabled(actions.setHarnessEnabled == nil)
      }
    }
  }
}

/// Reloads a pane when the server or the pane changes.
private struct LoadKey: Hashable {
  let server: String?
  let pane: ServerSettingsPane?
}
