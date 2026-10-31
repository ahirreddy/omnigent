import NativeLabCore
import SwiftUI

struct NewSessionView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var isCreating = false
  @State private var error: String?
  @State private var fixtureUncertain = false
  @State private var catalog: SessionCreationCatalog?
  @State private var selection = SessionCreationSelection()
  @State private var harnessID = ""
  @State private var workspaces: [CreationWorkspace] = []
  @State private var models: [ModelChoice] = []
  @State private var loadingCatalog = false
  @State private var loadingWorkspaces = false
  @State private var loadingModels = false
  @State private var workspaceError: String?
  @State private var modelError: String?
  @FocusState private var focusedField: Field?
  private enum Field: Hashable { case title, workspace, prompt }

  let onCreated: (String) -> Void

  private var fixture: String? {
    let arguments = ProcessInfo.processInfo.arguments
    guard arguments.contains("--ui-testing"), !model.isLive,
      let flag = arguments.first(where: { $0.hasPrefix("--ui-test-creation=") })
    else { return nil }
    return String(flag.dropFirst("--ui-test-creation=".count))
  }
  private var liveCreation: Bool { model.isLive || fixture != nil }
  private var needsReview: Bool { model.creationNeedsReview || fixtureUncertain }
  private var title: Binding<String> { draft("new-session-title") }
  private var prompt: Binding<String> { draft("new-session-prompt") }
  private func draft(_ key: String) -> Binding<String> {
    Binding(get: { model.drafts[key] ?? "" }, set: { model.setDraft($0, for: key) })
  }
  private var harnesses: [String] {
    Array(Set((catalog?.agents ?? []).map(\.harnessID).filter { !$0.isEmpty })).sorted()
  }
  private var agents: [CreationAgent] {
    (catalog?.agents ?? []).filter { $0.harnessID == harnessID }
  }
  private var availability: String? {
    guard liveCreation else { return nil }
    guard let catalog else { return "Load the host and agent choices before starting." }
    do {
      try catalog.validate(selection, models: models)
      return nil
    } catch { return error.localizedDescription }
  }
  private var canCreate: Bool {
    !isCreating && !needsReview && !loadingCatalog && !loadingModels
      && availability == nil
      && !prompt.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && title.wrappedValue.count <= 120
  }
  private var modelLoadKey: String { "\(selection.hostID)|\(selection.agentID)" }

  var body: some View {
    NavigationStack {
      Form {
        if liveCreation { destinationSection }
        Section {
          TextField("Name (optional)", text: title)
            .focused($focusedField, equals: .title)
            .accessibilityLabel("Session name")
            .accessibilityIdentifier("new-session-title")
          TextField("What would you like to work on?", text: prompt, axis: .vertical)
            .lineLimit(5...12)
            .focused($focusedField, equals: .prompt)
            .accessibilityLabel("First message")
            .accessibilityIdentifier("new-session-prompt")
        } header: {
          Text("Start a conversation")
        } footer: {
          Text(
            liveCreation
              ? "Creates a session on the selected host and opens it with your first message saved as a draft. Tap Send when the live connection is ready."
              : "This creates a sample session with a simulated reply. No server is connected.")
        }
        .disabled(isCreating || needsReview)
        if let error {
          Section {
            Label(error, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.red).accessibilityIdentifier("creation-error")
          }
        }
        if needsReview {
          Section {
            Text(SessionCreationError.uncertain.localizedDescription)
              .accessibilityIdentifier("creation-uncertain")
            Button("Close and review Sessions") { dismiss() }
              .accessibilityIdentifier("creation-review-sessions")
            Button("I checked Sessions; allow another creation") {
              model.acknowledgeCreationReview()
              fixtureUncertain = false
              error = nil
            }
            .accessibilityIdentifier("creation-acknowledge-review")
          }
        }
      }
      .navigationTitle("New session")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button {
            focusedField = nil
            Task { await create() }
          } label: {
            if isCreating {
              ProgressView("Starting conversation…")
            } else {
              Label("Start session", systemImage: "arrow.up")
            }
          }
          .disabled(!canCreate).accessibilityIdentifier("create-session")
        }
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }.disabled(isCreating)
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button("Done") { focusedField = nil }
            .accessibilityIdentifier("creation-dismiss-keyboard")
        }
      }
      .interactiveDismissDisabled(isCreating)
      .onDisappear { model.flushPersistence() }
      .task(id: model.connectionGeneration) {
        catalog = nil
        selection = SessionCreationSelection()
        harnessID = ""
        error = nil
        await loadCatalog()
      }
      .task(id: "\(model.connectionGeneration)|\(selection.hostID)") { await loadWorkspaces() }
      .task(id: "\(model.connectionGeneration)|\(modelLoadKey)") { await loadModels() }
      .onChange(of: harnessID) { _, _ in
        if !agents.contains(where: { $0.id == selection.agentID }) {
          selection.agentID =
            agents.first(where: {
              catalog?.unavailableReason(agentID: $0.id, hostID: selection.hostID) == nil
            })?.id ?? agents.first?.id ?? ""
          selection.model = nil
        }
      }
      .onChange(of: selection.hostID) { _, _ in
        selection.workspace = ""
        selection.model = nil
      }
      .onChange(of: selection.agentID) { _, _ in selection.model = nil }
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
  }

  @ViewBuilder
  private var destinationSection: some View {
    Section {
      if loadingCatalog { ProgressView("Loading hosts and agents…") }
      Picker("Host", selection: $selection.hostID) {
        Text("Choose a host").tag("")
        ForEach(catalog?.hosts ?? []) { host in
          Text("\(host.name)\(host.isAvailable ? "" : " (unavailable)")")
            .tag(host.id).disabled(!host.isAvailable)
        }
      }
      .accessibilityIdentifier("creation-host")
      Picker("Harness", selection: $harnessID) {
        Text("Choose a harness").tag("")
        ForEach(harnesses, id: \.self) { harness in
          Text(SessionConfiguration.harnessLabel(harness)).tag(harness)
        }
      }
      .accessibilityIdentifier("creation-harness")
      Picker("Agent", selection: $selection.agentID) {
        Text("Choose an agent").tag("")
        ForEach(agents) { agent in Text(agent.name).tag(agent.id) }
      }
      .accessibilityIdentifier("creation-agent")
      TextField("/absolute/workspace", text: $selection.workspace)
        .textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused($focusedField, equals: .workspace)
        .accessibilityLabel("Workspace path").accessibilityIdentifier("creation-workspace")
      if loadingWorkspaces { ProgressView("Loading host folders…") }
      if !workspaces.isEmpty {
        Menu("Choose a home folder") {
          ForEach(workspaces) { workspace in
            Button(workspace.path) { selection.workspace = workspace.path }
          }
        }
        .accessibilityIdentifier("creation-workspace-choices")
      }
      if let workspaceError {
        Text("Folders could not be loaded. Enter an absolute path. \(workspaceError)")
          .font(.footnote).foregroundStyle(.secondary)
      }
      Picker("Model", selection: $selection.model) {
        Text("Harness default").tag(String?.none)
        ForEach(models) { option in Text(option.title).tag(Optional(option.value)) }
      }
      .disabled(loadingModels || models.isEmpty).accessibilityIdentifier("creation-model")
      if loadingModels { ProgressView("Loading host model choices…") }
      if let modelError {
        Text("Model choices unavailable. Harness default remains available. \(modelError)")
          .font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("creation-model-notice")
      }
      if let availability {
        Text(availability).font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("creation-unavailable")
      }
      Button("Refresh choices") { Task { await refreshChoices() } }
        .disabled(loadingCatalog || loadingModels || loadingWorkspaces)
        .accessibilityIdentifier("creation-refresh")
    } header: {
      Text("Run on an existing host")
    } footer: {
      Text(
        "The server validates the workspace against the agent's filesystem access. Model choices preview this host's defaults; launch resolves the agent's final settings."
      )
    }
    .disabled(isCreating || needsReview)
  }

  @MainActor
  private func loadCatalog() async {
    guard liveCreation else { return }
    let generation = model.connectionGeneration
    loadingCatalog = true
    defer { if generation == model.connectionGeneration { loadingCatalog = false } }
    do {
      let value: SessionCreationCatalog
      if let fixtureCatalog {
        value = fixtureCatalog
      } else {
        value = try await model.loadSessionCreationCatalog()
      }
      guard !Task.isCancelled, generation == model.connectionGeneration else { return }
      catalog = value
      if selection.hostID.isEmpty {
        selection.hostID = value.hosts.first(where: \.isAvailable)?.id ?? ""
      }
      if selection.agentID.isEmpty {
        let agent =
          value.agents.first {
            value.unavailableReason(agentID: $0.id, hostID: selection.hostID) == nil
          } ?? value.agents.first
        harnessID = agent?.harnessID ?? ""
        selection.agentID = agent?.id ?? ""
      }
      error = nil
    } catch {
      guard !Task.isCancelled, generation == model.connectionGeneration else { return }
      catalog = nil
      self.error = error.localizedDescription
    }
  }

  @MainActor
  private func refreshChoices() async {
    await loadCatalog()
    await loadWorkspaces()
    await loadModels()
  }

  @MainActor
  private func loadWorkspaces() async {
    let hostID = selection.hostID
    let generation = model.connectionGeneration
    workspaces = []
    workspaceError = nil
    guard liveCreation, !hostID.isEmpty else {
      loadingWorkspaces = false
      return
    }
    loadingWorkspaces = true
    defer {
      if hostID == selection.hostID && generation == model.connectionGeneration {
        loadingWorkspaces = false
      }
    }
    do {
      let values: [CreationWorkspace]
      if fixture != nil {
        values = [CreationWorkspace(path: "/fixture/project", name: "project")]
      } else {
        values = try await model.loadCreationWorkspaces(hostID: hostID)
      }
      guard !Task.isCancelled, hostID == selection.hostID, generation == model.connectionGeneration
      else { return }
      workspaces = values
    } catch {
      guard !Task.isCancelled, hostID == selection.hostID, generation == model.connectionGeneration
      else { return }
      workspaceError = error.localizedDescription
    }
  }

  @MainActor
  private func loadModels() async {
    let key = modelLoadKey
    let generation = model.connectionGeneration
    models = []
    modelError = nil
    guard liveCreation, !selection.hostID.isEmpty, !selection.agentID.isEmpty else {
      loadingModels = false
      return
    }
    loadingModels = true
    defer {
      if key == modelLoadKey && generation == model.connectionGeneration { loadingModels = false }
    }
    do {
      let values: [ModelChoice]
      if fixture == "models-unavailable" {
        throw SessionCreationError.unavailable("Fixture catalog unavailable.")
      }
      if fixture != nil {
        values = try JSONDecoder().decode(
          [ModelChoice].self,
          from: Data(#"[{"id":"fixture-model","displayName":"Fixture model"}]"#.utf8))
      } else {
        values = try await model.loadCreationModels(
          agentID: selection.agentID, hostID: selection.hostID)
      }
      guard !Task.isCancelled, key == modelLoadKey, generation == model.connectionGeneration else {
        return
      }
      models = values
    } catch {
      guard !Task.isCancelled, key == modelLoadKey, generation == model.connectionGeneration else {
        return
      }
      modelError = error.localizedDescription
    }
    if let selected = selection.model, !models.contains(where: { $0.value == selected }) {
      selection.model = nil
    }
  }

  private var fixtureCatalog: SessionCreationCatalog? {
    guard let fixture else { return nil }
    return SessionCreationCatalog(
      hosts: [
        CreationHost(
          hostID: "fixture-host", name: "Fixture Mac", status: "online",
          configuredHarnesses: [
            "codex-native": fixture == "not-ready" ? .needsAuthentication : .ready
          ])
      ],
      agents: [CreationAgent(id: "fixture-agent", name: "Fixture Codex", harness: "codex-native")])
  }

  @MainActor
  private func create() async {
    guard canCreate else { return }
    let generation = model.connectionGeneration
    isCreating = true
    error = nil
    defer { isCreating = false }
    do {
      let sessionID: String
      if fixture == "uncertain" { throw SessionCreationError.uncertain }
      if model.isLive {
        sessionID = try await model.createLiveConversation(
          selection: selection, title: title.wrappedValue, prompt: prompt.wrappedValue)
      } else {
        sessionID = try await model.createConversation(
          title: title.wrappedValue, prompt: prompt.wrappedValue)
      }
      guard generation == model.connectionGeneration else { return }
      title.wrappedValue = ""
      prompt.wrappedValue = ""
      onCreated(sessionID)
    } catch {
      guard generation == model.connectionGeneration else { return }
      fixtureUncertain = fixture != nil && error as? SessionCreationError == .uncertain
      self.error = error.localizedDescription
    }
  }
}
