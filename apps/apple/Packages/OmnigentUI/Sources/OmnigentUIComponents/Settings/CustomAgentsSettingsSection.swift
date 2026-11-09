public import SwiftUI

/// One agent in Settings > Custom agents.
nonisolated public struct CustomAgentRow: Identifiable, Hashable, Sendable {
  /// Agent id.
  public let id: String
  /// Name.
  public let name: String
  /// Description.
  public let description: String?
  /// Harness label.
  public let harness: String
  /// Created.
  public let created: Date?
  /// Last edited.
  public let edited: Date?

  /// Creates a row.
  public init(
    id: String, name: String, description: String?, harness: String, created: Date?,
    edited: Date?
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.harness = harness
    self.created = created
    self.edited = edited
  }
}

/// An MCP server in an agent's configuration.
nonisolated public struct CustomAgentMCPServer: Identifiable, Hashable, Sendable {
  /// Tool name.
  public let id: String
  /// `stdio · npx -y …` or `http · https://…`.
  public let summary: String
  /// Can be changed or removed here.
  public let isEditable: Bool
  /// What the editor starts from.
  public var edit: MCPServerEdit?

  /// Creates a server.
  public init(id: String, summary: String, isEditable: Bool, edit: MCPServerEdit? = nil) {
    self.id = id
    self.summary = summary
    self.isEditable = isEditable
    self.edit = edit
  }
}

/// The editable configuration of one of the caller's agents.
nonisolated public struct CustomAgentConfigForm: Hashable, Sendable {
  /// Agent id.
  public var id: String
  /// Name (not editable).
  public var name: String
  /// Description.
  public var description: String
  /// Instructions.
  public var instructions: String
  /// Model.
  public var model: String
  /// Harness id.
  public var harness: String
  /// MCP servers.
  public var mcpServers: [CustomAgentMCPServer]
  /// Servers marked for removal.
  public var removedMCPServers: Set<String> = []
  /// Added servers and changes to editable ones, by name.
  public var mcpEdits: [String: MCPServerEdit] = [:]

  /// Creates the form.
  public init(
    id: String, name: String, description: String, instructions: String, model: String,
    harness: String, mcpServers: [CustomAgentMCPServer]
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.instructions = instructions
    self.model = model
    self.harness = harness
    self.mcpServers = mcpServers
  }
}

/// Settings > Custom agents.
public struct CustomAgentsSettingsState: Equatable, Sendable {
  /// The server's agents (read-only here).
  public var serverAgents: [CustomAgentRow]
  /// The caller's own agents.
  public var myAgents: [CustomAgentRow]
  /// Still loading.
  public var isLoading: Bool
  /// The agent being edited: loading (`nil` form) or loaded.
  public var editing: CustomAgentConfigForm?
  /// The editor is loading its configuration.
  public var isLoadingConfig: Bool
  /// Harnesses an agent can run on.
  public var harnesses: [AgentHarnessOption]
  /// A save or removal is in flight.
  public var isSaving: Bool
  /// Why loading or the last change failed.
  public var errorMessage: String?
  /// Sessions still use the agent being removed: the server's explanation.
  public var inUseMessage: String?

  /// Creates the state.
  public init(
    serverAgents: [CustomAgentRow] = [], myAgents: [CustomAgentRow] = [],
    isLoading: Bool = false, editing: CustomAgentConfigForm? = nil,
    isLoadingConfig: Bool = false, harnesses: [AgentHarnessOption] = [],
    isSaving: Bool = false, errorMessage: String? = nil, inUseMessage: String? = nil
  ) {
    self.serverAgents = serverAgents
    self.myAgents = myAgents
    self.isLoading = isLoading
    self.editing = editing
    self.isLoadingConfig = isLoadingConfig
    self.harnesses = harnesses
    self.isSaving = isSaving
    self.errorMessage = errorMessage
    self.inUseMessage = inUseMessage
  }
}

/// What Settings > Custom agents can do.
public struct CustomAgentsSettingsActions {
  /// Opens the create sheet.
  public var create: @MainActor () -> Void
  /// Opens one of the caller's agents for editing; `nil` where the server cannot read an
  /// agent's configuration (`agent_detail`).
  public var edit: (@MainActor (CustomAgentRow) -> Void)?
  /// Saves the editor.
  public var save: @MainActor (CustomAgentConfigForm) -> Void
  /// Removes an agent; `force` removes one sessions still use.
  public var remove: @MainActor (String, Bool) -> Void
  /// Closes the editor.
  public var closeEditor: @MainActor () -> Void

  /// Creates the actions.
  public init(
    create: @escaping @MainActor () -> Void,
    edit: (@MainActor (CustomAgentRow) -> Void)?,
    save: @escaping @MainActor (CustomAgentConfigForm) -> Void,
    remove: @escaping @MainActor (String, Bool) -> Void,
    closeEditor: @escaping @MainActor () -> Void
  ) {
    self.create = create
    self.edit = edit
    self.save = save
    self.remove = remove
    self.closeEditor = closeEditor
  }
}

/// Settings > Custom agents (the web's section): the server's agents, the caller's own with
/// Create, and an editor for one of the caller's agents (description, instructions, model,
/// harness, removing MCP servers) with Delete. Content for a grouped `Form`.
public struct CustomAgentsSettingsSection: View {
  private let state: CustomAgentsSettingsState
  private let actions: CustomAgentsSettingsActions
  @State private var search = ""
  @State private var draft: CustomAgentConfigForm?
  @State private var confirmsDelete: CustomAgentRow?
  @State private var pendingRemoval: String?
  @State private var editingServer: MCPServerEdit?

  /// Creates the section.
  public init(state: CustomAgentsSettingsState, actions: CustomAgentsSettingsActions) {
    self.state = state
    self.actions = actions
  }

  /// The section.
  public var body: some View {
    Group {
      if state.editing != nil || state.isLoadingConfig {
        editor
      } else {
        list
      }
    }
    .onChange(of: state.editing, initial: true) { _, editing in draft = editing }
    .confirmationDialog(
      "Delete \(confirmsDelete?.name ?? "agent")?", isPresented: deleteBinding,
      presenting: confirmsDelete
    ) { agent in
      Button("Delete", role: .destructive) {
        pendingRemoval = agent.id
        actions.remove(agent.id, false)
      }
    } message: { _ in
      Text("New sessions can no longer use it.")
    }
  }

  private var deleteBinding: Binding<Bool> {
    Binding(get: { confirmsDelete != nil }, set: { if !$0 { confirmsDelete = nil } })
  }

  @ViewBuilder private var list: some View {
    Section {
      TextField("Search", text: $search, prompt: Text("Search agents"))
      messages
    }
    Section {
      if state.isLoading && state.myAgents.isEmpty { ProgressView() }
      ForEach(filter(state.myAgents)) { agent in
        HStack {
          agentLabel(agent)
          Spacer()
          if let edit = actions.edit {
            Button("Edit\u{2026}") { edit(agent) }
              .accessibilityIdentifier("custom-agent-edit-\(agent.name)")
          }
        }
        .contextMenu {
          Button("Delete\u{2026}", role: .destructive) { confirmsDelete = agent }
        }
      }
      if !state.isLoading && state.myAgents.isEmpty {
        Text("No custom agents yet. Create one to keep it available for new sessions.")
          .foregroundStyle(.secondary)
      }
    } header: {
      HStack {
        Text("Yours")
        Spacer()
        Button("Create", systemImage: "plus", action: actions.create)
          .accessibilityIdentifier("custom-agent-create")
      }
    }
    Section("Built-in & Server Agents") {
      ForEach(filter(state.serverAgents)) { agentLabel($0) }
      if !state.isLoading && state.serverAgents.isEmpty {
        Text("No server agents.").foregroundStyle(.secondary)
      }
    }
  }

  private func agentLabel(_ agent: CustomAgentRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(agent.name)
      if let description = agent.description, !description.isEmpty {
        Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }
      Text(detail(agent)).font(.caption).foregroundStyle(.tertiary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("custom-agent-\(agent.name)")
  }

  private func detail(_ agent: CustomAgentRow) -> String {
    var parts = [agent.harness]
    if let created = agent.created {
      parts.append("Created \(created.formatted(date: .abbreviated, time: .omitted))")
    }
    if let edited = agent.edited {
      parts.append("Edited \(edited.formatted(date: .abbreviated, time: .omitted))")
    }
    return parts.joined(separator: " \u{00B7} ")
  }

  private func filter(_ agents: [CustomAgentRow]) -> [CustomAgentRow] {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return agents }
    return agents.filter {
      "\($0.name) \($0.description ?? "")".lowercased().contains(needle)
    }
  }

  @ViewBuilder private var messages: some View {
    if let error = state.errorMessage {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(Theme.failure)
        .textSelection(.enabled)
        .accessibilityIdentifier("custom-agent-error")
    }
    if let inUse = state.inUseMessage, let id = pendingRemoval {
      VStack(alignment: .leading) {
        Label(inUse, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        Button("Remove Anyway", role: .destructive) { actions.remove(id, true) }
      }
    }
  }

  @ViewBuilder private var editor: some View {
    Section {
      Button("Custom Agents", systemImage: "chevron.left", action: actions.closeEditor)
        .buttonStyle(.borderless)
      messages
    }
    if let form = Binding(keepingLast: $draft) {
      Section(form.wrappedValue.name) {
        TextField("Description", text: form.description)
        Picker("Harness", selection: form.harness) {
          ForEach(state.harnesses) { Text($0.label).tag($0.id) }
          if !state.harnesses.contains(where: { $0.id == form.wrappedValue.harness }) {
            Text(form.wrappedValue.harness).tag(form.wrappedValue.harness)
          }
        }
        TextField("Model", text: form.model)
      }
      Section("Instructions") {
        TextEditor(text: form.instructions).frame(minHeight: 100)
      }
      mcpSection(form)
      Section {
        HStack {
          Button("Delete Agent\u{2026}", role: .destructive) {
            confirmsDelete = CustomAgentRow(
              id: form.wrappedValue.id, name: form.wrappedValue.name, description: nil,
              harness: "", created: nil, edited: nil)
          }
          Spacer()
          if state.isSaving { ProgressView().controlSize(.small) }
          Button("Save") { actions.save(form.wrappedValue) }
            .primaryActionStyle()
            .disabled(state.isSaving || form.wrappedValue == state.editing)
            .accessibilityIdentifier("custom-agent-save")
        }
      }
    } else {
      ProgressView()
    }
  }

  /// The agent's MCP servers, with Add, and Edit for the editable ones (the web's editor).
  private func mcpSection(_ form: Binding<CustomAgentConfigForm>) -> some View {
    Section {
      if form.wrappedValue.mcpServers.isEmpty, form.wrappedValue.mcpEdits.isEmpty {
        Text("None").foregroundStyle(.secondary)
      }
      ForEach(form.wrappedValue.mcpServers) { server in
        mcpRow(server, form: form)
      }
      ForEach(addedServers(form.wrappedValue)) { edit in
        HStack {
          Text(edit.name)
          Text("New").font(.caption).foregroundStyle(.secondary)
          Spacer()
          Button("Edit\u{2026}") { editingServer = edit }
          Button("Remove") { form.wrappedValue.mcpEdits[edit.name] = nil }
        }
      }
    } header: {
      HStack {
        Text("MCP Servers")
        Spacer()
        Button("Add", systemImage: "plus") { editingServer = MCPServerEdit(isNew: true) }
          .accessibilityIdentifier("custom-agent-add-mcp")
      }
    }
    .sheet(item: $editingServer) { server in
      MCPServerEditorSheet(
        server: server,
        taken: Set(form.wrappedValue.mcpServers.map(\.id))
          .union(form.wrappedValue.mcpEdits.keys).subtracting([server.originalName]),
        save: { edited in
          if !server.originalName.isEmpty, server.originalName != edited.name {
            form.wrappedValue.mcpEdits[server.originalName] = nil
          }
          form.wrappedValue.mcpEdits[edited.name] = edited
          editingServer = nil
        },
        cancel: { editingServer = nil })
    }
  }

  private func addedServers(_ form: CustomAgentConfigForm) -> [MCPServerEdit] {
    form.mcpEdits.values.filter(\.isNew).sorted { $0.name < $1.name }
  }

  private func mcpRow(
    _ server: CustomAgentMCPServer, form: Binding<CustomAgentConfigForm>
  ) -> some View {
    let removed = form.wrappedValue.removedMCPServers.contains(server.id)
    return HStack {
      VStack(alignment: .leading) {
        Text(server.id).strikethrough(removed)
        Text(server.summary).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      if server.isEditable, !removed, let edit = server.edit {
        Button("Edit\u{2026}") { editingServer = form.wrappedValue.mcpEdits[server.id] ?? edit }
      }
      if server.isEditable {
        Button(removed ? "Keep" : "Remove") {
          if removed {
            form.wrappedValue.removedMCPServers.remove(server.id)
          } else {
            form.wrappedValue.removedMCPServers.insert(server.id)
          }
        }
      }
    }
  }
}
