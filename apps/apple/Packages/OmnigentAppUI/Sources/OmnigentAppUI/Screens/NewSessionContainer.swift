import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The web's new-session page over the core's ``CreationStore``: the composer in start mode with
/// the host (or a new sandbox, or Connect a Host), the agent grouped as on the web (with Create
/// Custom Agent and Import Bundle), the model, effort, approval and Plan mode, attachments, and
/// under it the folder, worktree or sandbox repositories and a Set Up notice for a harness that
/// is not ready. Start creates the session and sends the first message immediately; creation is
/// never repeated, and an unclear outcome blocks until the user acknowledges it.
struct NewSessionContainer: View {
  let connection: ConnectionStore
  let open: @MainActor (String) -> Void

  @State private var draft = ""
  @State var selection = OmnigentCoreFFI.CreationSelection(
    hostId: "", agentId: "", workspace: "", model: nil)
  /// The folder the user chose; the workspace differs when starting in an existing worktree.
  @State private var folder = ""
  @State private var worktree = NewSessionWorktreeChoice.none
  @State var isSandbox = false
  @State private var repositories = ""
  @State private var creation: CreationStore?
  @State private var coreMissing = false
  @State var attachmentError: String?
  @State private var setupTarget: HarnessSetupTarget?
  @State private var harnessSetup: HarnessSetupStore?
  @State private var customAgents: CustomAgentsStore?
  @State private var isCreatingAgent = false
  @State private var isImportingBundle = false
  @State private var isConnectingHost = false
  @Environment(\.useThisMachine) private var useThisMachine
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if let creation {
        NewSessionPage(
          draft: $draft, composer: composerState(creation), actions: actions(creation),
          importSessions: importSessions(openURL), options: options(creation),
          optionActions: optionActions(creation)
        )
        .onChange(of: creation.phase) { _, phase in
          if case .created(let sessionID, nil) = phase {
            draft = ""
            creation.reset()
            open(sessionID)
          }
        }
        .sheet(item: $setupTarget, onDismiss: { Task { await reloadCatalog(creation) } }) {
          target in
          if let harnessSetup {
            HarnessSetupContainer(store: harnessSetup, target: target) { setupTarget = nil }
          }
        }
        .sheet(isPresented: $isCreatingAgent) {
          if let customAgents {
            CreateAgentContainer(
              store: customAgents, allowsImport: true,
              created: { agent in
                isCreatingAgent = false
                Task { await agentInstalled(agent, creation) }
              },
              cancel: { isCreatingAgent = false })
          }
        }
        .sheet(
          isPresented: $isConnectingHost, onDismiss: { Task { await reloadCatalog(creation) } }
        ) {
          ConnectHostSheet(
            serverURL: serverURLText, useThisMachine: useThisMachineHere,
            close: { isConnectingHost = false })
        }
        .agentBundleImporter(
          isPresented: $isImportingBundle, store: customAgents,
          imported: { agent in Task { await agentInstalled(agent, creation) } })
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
      customAgents = connection.customAgents()
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

  /// Reloads hosts and agents after a setup, an install or a new host, keeping the selection.
  private func reloadCatalog(_ creation: CreationStore) async {
    await creation.loadCatalog()
    await creation.selectionChanged(selection)
  }

  /// A new or imported agent: reload the catalog and select it.
  private func agentInstalled(_ agent: OmnigentCoreFFI.ManagedAgent, _ creation: CreationStore)
    async
  {
    await creation.loadCatalog()
    change(creation) {
      $0.agentId = agent.id
      $0.model = nil
      $0.reasoningEffort = nil
      $0.approvalMode = nil
      $0.planMode = false
    }
  }

  var selectedAgent: OmnigentCoreFFI.CreationAgent? {
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
      attachments: attachmentChips(creation), acceptsAttachments: !isSandbox,
      configuration: configuration,
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
    if let attachmentError, phase == .editing { return .failed(message: attachmentError) }
    return switch phase {
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
      addAttachments: { stage($0, in: creation) },
      removeAttachment: { chip in
        if let id = UUID(uuidString: chip.id) { creation.removeAttachment(id) }
      },
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
          $0.planMode = false
        }
      },
      acknowledgeUncertainDelivery: { creation.acknowledgeUncertain() },
      dismissDeliveryError: {
        attachmentError = nil
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
        connectHost: { isConnectingHost = true },
        selectApprovalMode: { option in
          selection.approvalMode = NewSessionAdapter.approvalMode(option, agent: selectedAgent)
        },
        togglePlan: planToggle(creation), isPlanOn: isPlanOn,
        createAgent: agentAction(creation) { isCreatingAgent = true },
        importAgentBundle: agentAction(creation) { isImportingBundle = true }))
  }

  /// `action` when agents can be installed here: the server reports `agent_install` and the
  /// session starts on a host (a managed sandbox has no create path for an uploaded bundle).
  private func agentAction(
    _ creation: CreationStore, _ action: @escaping @MainActor () -> Void
  ) -> (@MainActor () -> Void)? {
    !isSandbox && creation.catalog.value?.agentInstall == true ? action : nil
  }

  /// "Use This Mac" for this server, where the edition can run hosts.
  private var useThisMachineHere: (@MainActor () async -> String?)? {
    guard let useThisMachine, let url = URL(string: serverURLText) else { return nil }
    return { await useThisMachine(url) }
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
    let notice = harnessNotice(creation.catalog.value)
    return NewSessionOptions(
      folder: folder.isEmpty ? nil : folder,
      recentFolders: (creation.workspaces.value ?? []).map(\.path),
      isSandbox: isSandbox, repositories: repositories,
      offersWorktrees: !(creation.worktrees.value ?? []).isEmpty, worktrees: worktrees,
      worktree: worktree, harnessNotice: notice?.text, setUpName: notice?.name,
      isPlanMode: isPlanOn)
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
      setRepositories: { repositories = $0 },
      setUpHarness: {
        guard let harness = setupHarness else { return }
        if harnessSetup == nil { harnessSetup = connection.harnessSetup() }
        Task { await harnessSetup?.load() }
        setupTarget = HarnessSetupTarget(harness: harness, hostID: selection.hostId)
      })
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
