import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The web's new-session page over the core's ``CreationStore``: the composer in start mode with
/// the host (or a new sandbox), the agent grouped as on the web, the model, effort and approval
/// mode, and under it the folder, worktree or sandbox repositories. Start creates the session and
/// sends the first message immediately; creation is never repeated, and an unclear outcome
/// blocks until the user acknowledges it.
struct NewSessionContainer: View {
  let connection: ConnectionStore
  let open: @MainActor (String) -> Void

  @State private var draft = ""
  @State private var selection = OmnigentCoreFFI.CreationSelection(
    hostId: "", agentId: "", workspace: "", model: nil)
  /// The folder the user chose; the workspace differs when starting in an existing worktree.
  @State private var folder = ""
  @State private var worktree = NewSessionWorktreeChoice.none
  @State private var isSandbox = false
  @State private var repositories = ""
  @State private var creation: CreationStore?
  @State private var coreMissing = false

  var body: some View {
    Group {
      if let creation {
        NewSessionPage(
          draft: $draft, composer: composerState(creation), actions: actions(creation),
          options: options(creation), optionActions: optionActions(creation)
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
      let ordered = NewSessionAdapter.agents(catalog, hostID: selection.hostId).choices
      selection.agentId =
        ordered.first { $0.unavailableReason == nil }?.id ?? ordered.first?.id ?? ""
    }
    await creation.selectionChanged(selection)
  }

  private func change(
    _ creation: CreationStore, _ edit: (inout OmnigentCoreFFI.CreationSelection) -> Void
  ) {
    edit(&selection)
    let selection = selection
    Task { await creation.selectionChanged(selection) }
  }

  private var selectedAgent: OmnigentCoreFFI.CreationAgent? {
    creation?.catalog.value?.agents.first { $0.id == selection.agentId }
  }

  private func composerState(_ creation: CreationStore) -> ComposerViewState {
    let catalog = creation.catalog.value
    let hostID = isSandbox ? NewSessionAdapter.newSandboxHostID : selection.hostId
    let agents = catalog.map { NewSessionAdapter.agents($0, hostID: hostID) }
    let agent = selectedAgent
    var configuration = ComposerConfiguration(
      harness: agent?.harness, agentName: agent?.name, harnessChoices: agents?.choices ?? [],
      selectedAgentId: selection.agentId,
      modelOptions: isSandbox ? [] : NewSessionAdapter.models(creation.models.value ?? []),
      selectedModelId: selection.model, selectedEffort: selection.reasoningEffort)
    configuration.agentGroups = agents?.groups ?? [:]
    return ComposerViewState(
      availability: availability(creation), delivery: delivery(creation.phase),
      acceptsAttachments: false, configuration: configuration,
      placeholder: "Describe what to build\u{2026}",
      hosts: ComposerHosts(hosts: NewSessionAdapter.hosts(catalog), selectedID: hostID),
      approvalModes: isSandbox
        ? nil : NewSessionAdapter.approvalModes(agent, selected: selection.approvalMode),
      purpose: .start, context: context(catalog))
  }

  /// Where the session will run, and why it cannot, before the first send.
  private func context(_ catalog: OmnigentCoreFFI.CreationCatalog?) -> ExecutionContext {
    let host = catalog?.hosts.first { $0.hostId == selection.hostId }
    let agent = selectedAgent
    let server = connection.connectedServer
    return ExecutionContext(
      agent: agent?.name, harness: agent?.harness,
      host: isSandbox ? "New sandbox" : ExecutionContext.hostDisplayName(host?.name),
      hostKind: isSandbox || host?.sandboxProvider != nil ? .cloud : .machine,
      isHostOnline: isSandbox ? true : host.map { $0.status == "online" },
      server: ExecutionContext.serverDisplayName(
        name: server?.serverName, baseURL: server?.baseUrl),
      directory: isSandbox || selection.workspace.isEmpty ? nil : selection.workspace,
      sandbox: isSandbox
        ? "Managed sandbox \u{00B7} \(catalog?.sandboxProviders.first ?? "server default")"
        : host.map {
          $0.sandboxProvider.map { "Managed sandbox \u{00B7} \($0)" } ?? "None (runs on the host)"
        },
      unavailableReason: isSandbox
        ? nil
        : catalog.flatMap {
          creationUnavailableReason(
            catalog: $0, agentId: selection.agentId, hostId: selection.hostId)
        })
  }

  private func availability(_ creation: CreationStore) -> ComposerAvailability {
    switch creation.catalog {
    case .idle, .loading: return .unavailable(reason: "Loading hosts and agents\u{2026}")
    case .failed(let error): return .unavailable(reason: error.message)
    case .loaded:
      if isSandbox {
        return selectedAgent == nil ? .unavailable(reason: "Choose an agent.") : .available
      }
      if selection.workspace.isEmpty {
        return .unavailable(reason: "Choose the folder the session works in.")
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
      send: { start(creation) },
      selectModel: { model in
        change(creation) {
          let current = ComposerConfiguration(
            modelOptions: NewSessionAdapter.models(creation.models.value ?? []),
            selectedModelId: $0.model, selectedEffort: $0.reasoningEffort)
          $0.reasoningEffort = current.effortKept(selecting: model)
          $0.model = model
        }
      },
      selectEffort: { effort in selection.reasoningEffort = effort },
      // Models, efforts and launch modes belong to the agent: a new agent starts on its defaults.
      selectAgent: { agentID in
        change(creation) {
          $0.agentId = agentID
          $0.model = nil
          $0.reasoningEffort = nil
          $0.approvalMode = nil
        }
      },
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
        selectHost: { host in
          if host.id == NewSessionAdapter.newSandboxHostID {
            isSandbox = true
          } else {
            isSandbox = false
            change(creation) { $0.hostId = host.id }
            selectFolder(creation, folder)
          }
        },
        selectApprovalMode: { option in
          selection.approvalMode = NewSessionAdapter.approvalMode(option, agent: selectedAgent)
        }))
  }

  /// Creates the session on the chosen host or a new sandbox and sends the draft.
  private func start(_ creation: CreationStore) {
    let text = draft
    if isSandbox {
      let agentID = selection.agentId
      let repos = NewSessionOptions.repositoryList(repositories)
      Task {
        await creation.createInSandbox(
          agentID: agentID, title: "", workspaces: repos, firstMessage: text)
      }
    } else {
      let selection = selection
      Task { await creation.create(selection, title: "", firstMessage: text) }
    }
  }

  private func options(_ creation: CreationStore) -> NewSessionOptions {
    let worktrees = NewSessionAdapter.worktrees(creation.worktrees.value ?? [])
    return NewSessionOptions(
      folder: folder.isEmpty ? nil : folder,
      recentFolders: (creation.workspaces.value ?? []).map(\.path),
      isSandbox: isSandbox, repositories: repositories,
      offersWorktrees: !(creation.worktrees.value ?? []).isEmpty, worktrees: worktrees,
      worktree: worktree)
  }

  private func optionActions(_ creation: CreationStore) -> NewSessionOptionActions {
    NewSessionOptionActions(
      selectFolder: { path in selectFolder(creation, path) },
      browse: { path in
        let hostID = selection.hostId
        return await creation.directory(hostID: hostID, path: path)
          .map(NewSessionAdapter.listing)
          .mapError { FolderBrowseError(message: $0.message) }
      },
      selectWorktree: { choice in
        worktree = choice
        applyWorktree()
      },
      isValidBranch: { isValidBranchName(name: $0) },
      setRepositories: { repositories = $0 })
  }

  /// A new folder starts in the folder itself and reloads its repository's worktrees.
  private func selectFolder(_ creation: CreationStore, _ path: String) {
    folder = path
    worktree = .none
    applyWorktree()
    let hostID = selection.hostId
    Task { await creation.folderChanged(hostID: hostID, path: path) }
  }

  private func applyWorktree() {
    let resolved = NewSessionAdapter.git(worktree, folder: folder)
    selection.git = resolved.git
    selection.workspace = resolved.workspace
  }
}
