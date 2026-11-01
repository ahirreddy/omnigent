public import SwiftUI

/// The new-session sheet: pick a host, harness and agent, a workspace on that host and an
/// optional model, then create. Availability comes from the core and is shown as the reason the
/// Create button is disabled. An uncertain creation blocks another until the user has checked.
public struct NewSessionView: View {
  private let state: NewSessionViewState
  private let actions: NewSessionActions

  @State private var selection = CreationSelection()
  @State private var harness = ""
  @State private var title = ""
  @State private var firstMessage = ""
  @FocusState private var focusedField: Field?

  private enum Field: Hashable {
    case workspace
    case title
    case message
  }

  /// Creates the sheet.
  /// - Parameters:
  ///   - state: Catalog, folders, models and request state.
  ///   - actions: Host actions.
  ///   - initialSelection: A preselected host, agent or workspace.
  public init(
    state: NewSessionViewState, actions: NewSessionActions,
    initialSelection: CreationSelection = CreationSelection()
  ) {
    self.state = state
    self.actions = actions
    _selection = State(initialValue: initialSelection)
  }

  private var catalog: CreationCatalog? { state.catalog.value }

  private var harnesses: [String] {
    let ids = (catalog?.agents ?? []).compactMap { $0.harness }.filter { !$0.isEmpty }
    return Array(Set(ids)).sorted()
  }

  private var agents: [CreationAgent] {
    (catalog?.agents ?? []).filter { harness.isEmpty || $0.harness == harness }
  }

  private var isBusy: Bool {
    if case .creating = state.phase { return true }
    return false
  }

  private var isUncertain: Bool {
    if case .uncertain = state.phase { return true }
    return false
  }

  private var blockedReason: String? {
    if catalog == nil { return "Load the hosts and agents first." }
    if isUncertain { return "Check Sessions before creating another." }
    if title.count > 120 { return "Titles can be up to 120 characters." }
    return actions.unavailableReason(selection)
  }

  /// The sheet.
  public var body: some View {
    NavigationStack {
      Form {
        destinationSection
        conversationSection
        CreationStatusSection(
          phase: state.phase, blockedReason: catalog == nil ? nil : blockedReason,
          acknowledge: actions.acknowledgeUncertain)
      }
      .formStyle(.grouped)
      .disabled(isBusy)
      .navigationTitle("New Session")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: actions.cancel)
            .disabled(isBusy)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            actions.create(selection, title, firstMessage)
          } label: {
            if isBusy {
              ProgressView().controlSize(.small)
            } else {
              Text("Create")
            }
          }
          .disabled(blockedReason != nil || isBusy)
          .help(blockedReason ?? "Create the session")
          .accessibilityIdentifier("create-session")
        }
      }
    }
    .interactiveDismissDisabled(isBusy)
    #if os(macOS)
      .frame(minWidth: 480, idealWidth: 540, minHeight: 520)
    #endif
    .onChange(of: harness) { _, _ in
      if !agents.contains(where: { $0.id == selection.agentId }) {
        selection.agentId =
          agents.first { actions.unavailableReason(withAgent($0.id)) == nil }?.id
          ?? agents.first?.id ?? ""
      }
    }
    .onChange(of: selection.hostId) { _, _ in
      selection.workspace = ""
      selection.model = nil
      actions.selectionChanged?(selection)
    }
    .onChange(of: selection.agentId) { _, _ in
      selection.model = nil
      actions.selectionChanged?(selection)
    }
  }

  private func withAgent(_ id: String) -> CreationSelection {
    var copy = selection
    copy.agentId = id
    return copy
  }

  @ViewBuilder private var destinationSection: some View {
    Section {
      switch state.catalog {
      case .idle, .loading:
        HStack {
          ProgressView().controlSize(.small)
          Text("Loading hosts and agents").foregroundStyle(.secondary)
        }
      case .failed(let message):
        VStack(alignment: .leading, spacing: 8) {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.failure)
            .textSelection(.enabled)
          if let reload = actions.reload { Button("Try Again", action: reload) }
        }
        .accessibilityIdentifier("creation-catalog-error")
      case .loaded(let catalog):
        hostPicker(catalog)
        Picker("Harness", selection: $harness) {
          Text("Any harness").tag("")
          ForEach(harnesses, id: \.self) { id in
            Text(HarnessAppearance(harness: id).label).tag(id)
          }
        }
        .accessibilityIdentifier("creation-harness")
        Picker("Agent", selection: $selection.agentId) {
          Text("Choose an agent").tag("")
          ForEach(agents) { agent in
            Text(agent.name.isEmpty ? agent.id : agent.name).tag(agent.id)
          }
        }
        .accessibilityIdentifier("creation-agent")
        if let agent = catalog.agents.first(where: { $0.id == selection.agentId }),
          let description = agent.description, !description.isEmpty
        {
          Text(description).font(.caption).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Where")
    }
    Section {
      LabeledContent("Workspace") {
        TextField("Workspace", text: $selection.workspace, prompt: Text("/absolute/path/on/host"))
          .labelsHidden()
          .font(Theme.codeFont)
          .autocorrectionDisabled()
          #if os(iOS)
            .textInputAutocapitalization(.never)
          #endif
          .focused($focusedField, equals: .workspace)
          .accessibilityIdentifier("creation-workspace")
        workspaceMenu
      }
      if let error = state.workspaces.errorMessage {
        Text("Folders could not be loaded: \(error) Enter an absolute path.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      modelPicker
    } header: {
      Text("Workspace and Model")
    }
  }

  private func hostPicker(_ catalog: CreationCatalog) -> some View {
    Picker("Host", selection: $selection.hostId) {
      Text("Choose a host").tag("")
      ForEach(catalog.hosts) { host in
        HStack {
          Text(host.name)
          if !host.isAvailable {
            Text(host.sandboxProvider == nil ? "Offline" : "Managed").foregroundStyle(.secondary)
          }
        }
        .tag(host.hostId)
      }
    }
    .accessibilityIdentifier("creation-host")
  }

  @ViewBuilder private var workspaceMenu: some View {
    switch state.workspaces {
    case .loading:
      ProgressView().controlSize(.small)
    case .loaded(let workspaces) where !workspaces.isEmpty:
      Menu {
        ForEach(workspaces) { workspace in
          Button(workspace.path) { selection.workspace = workspace.path }
        }
      } label: {
        Label("Choose a Folder", systemImage: "folder")
      }
      .labelStyle(.iconOnly)
      .menuIndicator(.hidden)
      .fixedSize()
      .accessibilityIdentifier("creation-workspace-choices")
    case .idle, .loaded, .failed:
      EmptyView()
    }
  }

  @ViewBuilder private var modelPicker: some View {
    let models = state.models.value?.filter { !$0.hidden } ?? []
    Picker("Model", selection: $selection.model) {
      Text("Harness default").tag(String?.none)
      ForEach(models) { option in
        Text(option.label).tag(Optional(option.model ?? option.id))
      }
    }
    .disabled(models.isEmpty)
    .accessibilityIdentifier("creation-model")
    if state.models.isLoading {
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading models").font(.caption).foregroundStyle(.secondary)
      }
    } else if let error = state.models.errorMessage {
      Text("Models could not be loaded: \(error)").font(.caption).foregroundStyle(.secondary)
    }
  }

  private var conversationSection: some View {
    Section {
      TextField("Title", text: $title, prompt: Text("Optional"))
        .focused($focusedField, equals: .title)
        .accessibilityIdentifier("creation-title")
      TextField(
        "First message", text: $firstMessage, prompt: Text("What should the agent work on?"),
        axis: .vertical
      )
      .lineLimit(3...8)
      .focused($focusedField, equals: .message)
      .accessibilityIdentifier("creation-first-message")
    } header: {
      Text("Conversation")
    } footer: {
      Text(
        "The first message is kept as a draft in the new session, so you can review it before sending."
      )
    }
  }
}

/// Where the creation request stands: why Create is disabled, progress, a rejection, or an
/// uncertain result that blocks another creation until the user has checked.
private struct CreationStatusSection: View {
  let phase: CreationPhase
  let blockedReason: String?
  let acknowledge: (@MainActor () -> Void)?

  var body: some View {
    switch phase {
    case .editing:
      if let reason = blockedReason {
        Section {
          Label(reason, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("creation-blocked-reason")
        }
      }
    case .creating:
      Section {
        HStack {
          ProgressView().controlSize(.small)
          Text("Creating the session")
        }
      }
    case .failed(let message):
      Section {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(Theme.failure)
          .textSelection(.enabled)
          .accessibilityIdentifier("creation-error")
      }
    case .uncertain(let message):
      Section {
        Label(message, systemImage: "questionmark.circle.fill")
          .foregroundStyle(Theme.attention)
          .accessibilityIdentifier("creation-uncertain")
        if let acknowledge {
          Button("I Checked Sessions, Allow Another", action: acknowledge)
        }
      }
    }
  }
}
