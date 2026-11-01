import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The web's new-session page over the core's ``CreationStore``: the composer in start mode with
/// the host, agent, folder and model the server offers. Start creates the session and sends the
/// first message immediately; creation is never repeated, and an unclear outcome blocks until
/// the user acknowledges it.
struct NewSessionContainer: View {
  let connection: ConnectionStore
  let open: @MainActor (String) -> Void

  @State private var draft = ""
  @State private var selection = OmnigentCoreFFI.CreationSelection(
    hostId: "", agentId: "", workspace: "", model: nil)
  @State private var creation: CreationStore?
  @State private var coreMissing = false

  var body: some View {
    Group {
      if let creation {
        NewSessionPage(
          draft: $draft, composer: composerState(creation), actions: actions(creation)
        )
        .onChange(of: creation.phase) { _, phase in
          if case .created(let sessionID, nil) = phase {
            draft = ""
            creation.reset()
            open(sessionID)
          }
        }
      } else if coreMissing {
        ContentUnavailableView(
          "Cannot Start Sessions", systemImage: "exclamationmark.triangle",
          description: Text(
            connection.issues.last?.error.message ?? "The client core did not start."))
      } else {
        ProgressView()
      }
    }
    .task {
      guard let creation = connection.creation() else {
        coreMissing = true
        return
      }
      self.creation = creation
      await load(creation)
    }
  }

  private func load(_ creation: CreationStore) async {
    if creation.catalog.value == nil { await creation.loadCatalog() }
    guard let catalog = creation.catalog.value else { return }
    if selection.hostId.isEmpty {
      let host = catalog.hosts.first(where: \.isAvailable) ?? catalog.hosts.first
      selection.hostId = host?.hostId ?? ""
    }
    if selection.agentId.isEmpty {
      selection.agentId = catalog.agents.first(where: \.supportsCreation)?.id ?? ""
    }
    await creation.selectionChanged(selection)
    if selection.workspace.isEmpty, let first = creation.workspaces.value?.first {
      selection.workspace = first.path
    }
  }

  private func change(
    _ creation: CreationStore, _ edit: (inout OmnigentCoreFFI.CreationSelection) -> Void
  ) {
    edit(&selection)
    let selection = selection
    Task { await creation.selectionChanged(selection) }
  }

  private func composerState(_ creation: CreationStore) -> ComposerViewState {
    let catalog = creation.catalog.value
    let hosts = (catalog?.hosts ?? []).map { host in
      ComposerHost(
        id: host.hostId, name: host.name, kind: host.sandboxProvider == nil ? .machine : .cloud,
        isOnline: host.isAvailable)
    }
    let agents = (catalog?.agents ?? []).filter(\.supportsCreation).map { agent in
      OmnigentUIComponents.HarnessChoice(
        id: agent.id, name: agent.name, harness: agent.harness, builtin: nil)
    }
    let models = (creation.models.value ?? []).filter { $0.hidden != true }.map { choice in
      OmnigentUIComponents.ModelOption(
        id: choice.value, model: choice.model, displayName: choice.title,
        defaultReasoningEffort: choice.defaultReasoningEffort,
        supportedReasoningEfforts: (choice.supportedReasoningEfforts ?? []).map(\.reasoningEffort),
        isDefault: choice.isDefault ?? false, hidden: false)
    }
    return ComposerViewState(
      availability: availability(creation), delivery: delivery(creation.phase),
      configuration: ComposerConfiguration(
        harnessChoices: agents, selectedAgentId: selection.agentId, modelOptions: models,
        selectedModelId: selection.model),
      placeholder: "Describe what to build\u{2026}",
      hosts: ComposerHosts(hosts: hosts, selectedID: selection.hostId),
      tray: ComposerTray(
        directory: selection.workspace.isEmpty ? nil : selection.workspace,
        recentDirectories: (creation.workspaces.value ?? []).map(\.path)),
      purpose: .start)
  }

  private func availability(_ creation: CreationStore) -> ComposerAvailability {
    switch creation.catalog {
    case .idle, .loading: return .unavailable(reason: "Loading hosts and agents\u{2026}")
    case .failed(let error): return .unavailable(reason: error.message)
    case .loaded:
      if case .failed(let error) = creation.workspaces {
        return .unavailable(reason: error.message)
      }
      return creation.unavailableReason(selection).map { .unavailable(reason: $0) } ?? .available
    }
  }

  private func delivery(_ phase: OmnigentStores.CreationPhase) -> DeliveryState {
    switch phase {
    case .editing: .idle
    case .creating: .sending
    case .failed(let error): .failed(message: error.message)
    case .uncertain(let error):
      .uncertain(
        message: "The session may have been created: \(error.message) Check Sessions first.")
    case .created(_, nil): .idle
    case .created(_, .some(let error)):
      .failed(message: "The session was created, but the first message failed: \(error.message)")
    }
  }

  private func actions(_ creation: CreationStore) -> ComposerActions {
    ComposerActions(
      send: {
        let text = draft
        let selection = selection
        Task { await creation.create(selection, title: "", firstMessage: text) }
      },
      selectModel: { model in change(creation) { $0.model = model } },
      selectAgent: { agentID in change(creation) { $0.agentId = agentID } },
      acknowledgeUncertainDelivery: { creation.acknowledgeUncertain() },
      dismissDeliveryError: {
        if case .created(let sessionID, .some) = creation.phase {
          // The session exists; open it so the user can send again there.
          creation.reset()
          open(sessionID)
        } else {
          creation.reset()
        }
      },
      extras: ComposerExtraActions(
        selectHost: { host in change(creation) { $0.hostId = host.id } },
        selectDirectory: { path in change(creation) { $0.workspace = path } }))
  }
}
