public import SwiftUI

/// Server settings as native panes: a server picker, then the panes the server and caller offer
/// (Account, Harnesses, MCP, Integrations, Git, Import, the Admin panes and Archived sessions).
/// Each pane loads when shown. The Mac Settings window shows them as a sidebar and a detail;
/// iPhone and iPad as a list inside the host's `NavigationStack`, under the host's own rows,
/// each pane pushed by its ``ServerSettingsPane`` value.
public struct ServerSettingsView: View {
  private let state: ServerSettingsViewState
  @Binding private var selectedServer: String?
  private let actions: ServerSettingsActions
  private let hostedPane: (ServerSettingsPane) -> AnyView?
  private let selectedPane: Binding<ServerSettingsPane?>?
  private let leadingSections: AnyView?
  @State private var localPane: ServerSettingsPane?

  /// Creates the settings.
  /// - Parameters:
  ///   - state: The selected server's settings.
  ///   - selectedServer: The server whose settings show.
  ///   - selectedPane: The shown pane, so the host can open one; the view keeps its own when
  ///     `nil`. The Mac layout only: iPhone and iPad push panes on the host's path.
  ///   - actions: Loads and changes.
  ///   - leadingSections: The host's own list sections above the server's panes (iPhone and
  ///     iPad), for example General and Appearance.
  ///   - hostedPane: A pane the host draws itself (for example Harnesses over the app's stores),
  ///     or `nil` for the built-in one.
  public init(
    state: ServerSettingsViewState, selectedServer: Binding<String?>,
    selectedPane: Binding<ServerSettingsPane?>? = nil, actions: ServerSettingsActions,
    leadingSections: AnyView? = nil,
    hostedPane: @escaping (ServerSettingsPane) -> AnyView? = { _ in nil }
  ) {
    self.state = state
    _selectedServer = selectedServer
    self.selectedPane = selectedPane
    self.actions = actions
    self.leadingSections = leadingSections
    self.hostedPane = hostedPane
  }

  private var pane: Binding<ServerSettingsPane?> { selectedPane ?? $localPane }

  private var shownPane: ServerSettingsPane? {
    pane.wrappedValue.flatMap { state.panes.contains($0) ? $0 : nil } ?? state.panes.first
  }

  /// The settings.
  public var body: some View {
    #if os(macOS)
      splitLayout
    #else
      stackLayout
    #endif
  }

  #if os(macOS)
    private var splitLayout: some View {
      NavigationSplitView {
        List(selection: pane) {
          paneSections { Label($0.title, systemImage: $0.systemImage).tag($0) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
          serverPicker
            .labelsHidden()
            .padding(Theme.Spacing.medium)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
      } detail: {
        paneForm(shownPane)
      }
      .frame(minWidth: 720, minHeight: 480)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("server-settings")
    }
  #else
    private var stackLayout: some View {
      List {
        leadingSections
        if state.servers.count > 1 {
          Section { serverPicker }
        }
        if let error = state.errorMessage {
          Section { errorLabel(error) }
        }
        paneSections { pane in
          NavigationLink(value: pane) {
            // Theme ink, as the sidebar's rows, not the system blue.
            Label(pane.title, systemImage: pane.systemImage)
              .foregroundStyle(ThemeColor.primary)
          }
          .accessibilityIdentifier("server-settings-pane-\(pane.rawValue)")
        }
      }
      .navigationDestination(for: ServerSettingsPane.self) { paneForm($0) }
      .task(id: selectedServer) { actions.loadServer?() }
      .accessibilityIdentifier("server-settings")
    }
  #endif

  /// The panes, with the Admin ones and Archived in sections of their own.
  @ViewBuilder
  private func paneSections<Row: View>(row: @escaping (ServerSettingsPane) -> Row) -> some View {
    Section {
      ForEach(state.panes.filter { !$0.isAdmin && $0 != .archived }, content: row)
    } header: {
      #if os(iOS)
        Text(serverName)
      #endif
    }
    let admin = state.panes.filter(\.isAdmin)
    if !admin.isEmpty {
      Section("Admin") { ForEach(admin, content: row) }
    }
    if state.panes.contains(.archived) {
      Section { row(.archived) }
    }
  }

  #if os(iOS)
    private var serverName: String {
      state.servers.first { $0.id == selectedServer }?.name ?? "Server"
    }
  #endif

  private var serverPicker: some View {
    Picker("Server", selection: $selectedServer) {
      ForEach(state.servers) { server in
        Text(server.name).tag(Optional(server.id))
      }
    }
    .accessibilityIdentifier("server-settings-picker")
  }

  private func errorLabel(_ error: String) -> some View {
    Label(error, systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(Theme.failure)
      .textSelection(.enabled)
  }

  /// One pane's form, loading its data when the server or the pane changes.
  private func paneForm(_ pane: ServerSettingsPane?) -> some View {
    paneBody(pane)
      .navigationTitle(pane?.title ?? "Server Settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .task(id: LoadKey(server: selectedServer, pane: pane)) {
        if let pane { actions.load?(pane) }
      }
      .accessibilityIdentifier(
        pane.map { "server-settings-\($0.rawValue)" } ?? "server-settings-none")
  }

  @ViewBuilder private func paneBody(_ pane: ServerSettingsPane?) -> some View {
    #if os(iOS)
      // A hosted pane is a form of its own; inside another it lays out at zero height.
      if let pane, let hosted = hostedPane(pane) {
        hosted
      } else {
        builtInForm(pane)
      }
    #else
      builtInForm(pane)
    #endif
  }

  private func builtInForm(_ pane: ServerSettingsPane?) -> some View {
    Form {
      if let error = state.errorMessage {
        Section { errorLabel(error) }
      }
      if state.isLoading {
        ProgressView().frame(maxWidth: .infinity)
      }
      if let pane, let hosted = hostedPane(pane) {
        hosted
      } else {
        builtInPane(pane)
      }
    }
    .formStyle(.grouped)
    .disabled(state.isSaving)
  }

  @ViewBuilder private func builtInPane(_ pane: ServerSettingsPane?) -> some View {
    switch pane {
    case .account: AccountSettingsPane(account: state.account, actions: actions)
    case .harnesses: harnesses
    case .customAgents: Text("Custom agents are not available here.").foregroundStyle(.secondary)
    case .mcp:
      MCPPane(services: state.mcpServices, actions: actions, errorMessage: state.errorMessage)
    case .integrations: IntegrationsPane(connections: state.connections, actions: actions)
    case .git: GitSettingsPane(archiveWorktreeCleanup: state.archiveWorktreeCleanup)
    case .importSessions:
      ImportSessionsPane(hosts: state.importHosts, sources: state.importSources, actions: actions)
    case .archived:
      ArchivedSessionsPane(
        sessions: state.archived, info: state.archivedInfo, projects: state.archivedProjects,
        hasMore: state.hasMoreArchived, actions: actions)
    case .some(let admin): adminPane(admin)
    case nil: Text("Sign in to a server to see its settings.").foregroundStyle(.secondary)
    }
  }

  /// Members, Policies and Sharing.
  @ViewBuilder private func adminPane(_ pane: ServerSettingsPane) -> some View {
    switch pane {
    case .members:
      MembersPane(members: state.members, actions: actions, errorMessage: state.errorMessage)
    case .policies:
      PoliciesPane(
        policies: state.policies, templates: state.policyTemplates, actions: actions,
        errorMessage: state.errorMessage)
    case .sharing: SharingPane(sharing: state.sharing, actions: actions)
    default: EmptyView()
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
