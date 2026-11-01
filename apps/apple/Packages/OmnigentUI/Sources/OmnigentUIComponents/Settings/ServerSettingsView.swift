public import SwiftUI

/// Server settings as native panes for the Mac Settings window: a server picker, then
/// Harnesses, MCP, Git, Members, Policies, Sharing and Archived sessions. Admin panes are
/// read-only for non-admins.
public struct ServerSettingsView: View {
  private let state: ServerSettingsViewState
  @Binding private var selectedServer: String?
  private let actions: ServerSettingsActions
  @State private var pane: ServerSettingsPane? = .harnesses

  /// Creates the settings.
  /// - Parameters:
  ///   - state: The selected server's settings.
  ///   - selectedServer: The server whose settings show.
  ///   - actions: Changes.
  public init(
    state: ServerSettingsViewState, selectedServer: Binding<String?>, actions: ServerSettingsActions
  ) {
    self.state = state
    _selectedServer = selectedServer
    self.actions = actions
  }

  /// The settings.
  public var body: some View {
    NavigationSplitView {
      List(ServerSettingsPane.allCases, selection: $pane) { pane in
        Label(pane.title, systemImage: pane.systemImage).tag(pane)
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        Picker("Server", selection: $selectedServer) {
          ForEach(state.servers) { server in
            Text(server.name).tag(Optional(server.id))
          }
        }
        .labelsHidden()
        .padding(10)
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
        paneContent
      }
      .formStyle(.grouped)
      .navigationTitle(pane?.title ?? "Server Settings")
    }
    .frame(minWidth: 680, minHeight: 460)
    .accessibilityIdentifier("server-settings")
  }

  @ViewBuilder private var paneContent: some View {
    switch pane {
    case .harnesses, nil:
      Section {
        ForEach(state.harnesses) { harness in
          Toggle(
            isOn: Binding(
              get: { harness.isEnabled }, set: { actions.setHarnessEnabled?(harness, $0) })
          ) {
            HStack(spacing: 8) {
              HarnessGlyph(harness: harness.harness, size: 18)
              VStack(alignment: .leading) {
                Text(harness.name)
                if let note = harness.note { Text(note).font(.caption).foregroundStyle(.secondary) }
              }
            }
          }
          .disabled(actions.setHarnessEnabled == nil)
        }
      } footer: {
        Text("Hide unconfigured harnesses from the model menu in Settings > Appearance.")
      }
    case .mcp:
      toggles(state.mcpServers, set: actions.setMCPEnabled)
      if let add = actions.addMCPServer {
        Button("Add MCP Server\u{2026}", action: add)
      }
    case .git:
      toggles(state.gitProviders, set: actions.setGitConnected)
    case .members:
      Section {
        ForEach(state.members) { member in
          LabeledContent {
            Picker(
              "Role",
              selection: Binding(get: { member.role }, set: { actions.setMemberRole?(member, $0) })
            ) {
              Text("Admin").tag("Admin")
              Text("Member").tag("Member")
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!state.isAdmin || actions.setMemberRole == nil)
          } label: {
            HStack(spacing: 8) {
              AuthorAvatar(name: member.name)
              VStack(alignment: .leading) {
                Text(member.name)
                Text(member.email).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      } footer: {
        if !state.isAdmin { Text("Only admins can change roles.") }
      }
    case .policies:
      toggles(state.policies, set: state.isAdmin ? actions.setPolicyEnabled : nil)
    case .sharing:
      Toggle(
        "Allow sharing sessions",
        isOn: Binding(get: { state.sharingEnabled }, set: { actions.setSharingEnabled?($0) })
      )
      .disabled(!state.isAdmin || actions.setSharingEnabled == nil)
    case .archived:
      if state.archived.isEmpty {
        Text("No archived sessions").foregroundStyle(.secondary)
      }
      ForEach(state.archived) { session in
        LabeledContent(session.title) {
          if let unarchive = actions.unarchive {
            Button("Unarchive") { unarchive(session) }
          }
        }
      }
    }
  }

  private func toggles(
    _ rows: [ServerSettingRow], set: (@MainActor (ServerSettingRow, Bool) -> Void)?
  ) -> some View {
    Section {
      if rows.isEmpty { Text("None").foregroundStyle(.secondary) }
      ForEach(rows) { row in
        Toggle(isOn: Binding(get: { row.isEnabled }, set: { set?(row, $0) })) {
          VStack(alignment: .leading) {
            Text(row.name)
            if !row.detail.isEmpty { Text(row.detail).font(.caption).foregroundStyle(.secondary) }
          }
        }
        .disabled(set == nil)
      }
    }
  }
}
