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
  @State private var form = NewSessionForm()
  @State private var creation: CreationStore?
  @State private var coreMissing = false
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
        page(creation)
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
      await form.load(creation)
    }
  }

  private func page(_ creation: CreationStore) -> some View {
    NewSessionPage(
      draft: $draft, composer: form.composerState(creation, connection: connection),
      actions: actions(creation), importSessions: importSessions(openURL),
      options: form.options(creation), optionActions: optionActions(creation)
    )
    .onChange(of: creation.phase) { _, phase in
      if case .created(let sessionID, nil) = phase {
        draft = ""
        creation.reset()
        open(sessionID)
      }
    }
    .sheet(
      item: $setupTarget, onDismiss: { Task { await form.reloadCatalog(creation) } },
      content: { target in harnessSetupSheet(target) }
    )
    .sheet(isPresented: $isCreatingAgent, content: { createAgentSheet(creation) })
    .sheet(
      isPresented: $isConnectingHost,
      onDismiss: { Task { await form.reloadCatalog(creation) } },
      content: {
        ConnectHostSheet(
          serverURL: serverURLText, useThisMachine: useThisMachineHere,
          close: { isConnectingHost = false })
      }
    )
    .agentBundleImporter(
      isPresented: $isImportingBundle, store: customAgents,
      imported: { agent in Task { await form.agentInstalled(agent, creation) } })
  }

  @ViewBuilder private func harnessSetupSheet(_ target: HarnessSetupTarget) -> some View {
    if let harnessSetup {
      HarnessSetupContainer(store: harnessSetup, target: target) { setupTarget = nil }
    }
  }

  @ViewBuilder private func createAgentSheet(_ creation: CreationStore) -> some View {
    if let customAgents {
      CreateAgentContainer(
        store: customAgents, allowsImport: true,
        created: { agent in
          isCreatingAgent = false
          Task { await form.agentInstalled(agent, creation) }
        },
        cancel: { isCreatingAgent = false })
    }
  }

  private func actions(_ creation: CreationStore) -> ComposerActions {
    let form = form
    return ComposerActions(
      send: { form.start(creation, text: draft) },
      addAttachments: { form.stage($0, in: creation) },
      removeAttachment: { chip in
        if let id = UUID(uuidString: chip.id) { creation.removeAttachment(id) }
      },
      selectModel: { model in
        form.change(creation) {
          let current = ComposerConfiguration(
            modelOptions: NewSessionAdapter.models(creation.models.value ?? []),
            selectedModelId: $0.model, selectedEffort: $0.reasoningEffort)
          $0.reasoningEffort = current.effortKept(selecting: model)
          $0.model = model
        }
      },
      selectEffort: { effort in form.selection.reasoningEffort = effort },
      selectAgent: { agentID in form.selectAgent(agentID, creation) },
      acknowledgeUncertainDelivery: { creation.acknowledgeUncertain() },
      dismissDeliveryError: {
        form.attachmentError = nil
        if case .created(let sessionID, .some) = creation.phase {
          // The session exists; open it so the user can send again there.
          creation.reset()
          open(sessionID)
        } else {
          creation.reset()
        }
      },
      extras: extraActions(creation))
  }

  private func extraActions(_ creation: CreationStore) -> ComposerExtraActions {
    let form = form
    return ComposerExtraActions(
      selectHost: { host in
        if host.id == NewSessionAdapter.newSandboxHostID {
          form.isSandbox = true
        } else {
          form.isSandbox = false
          form.change(creation) { $0.hostId = host.id }
          form.selectFolder(creation, form.folder)
        }
      },
      connectHost: { isConnectingHost = true },
      selectApprovalMode: { option in
        form.selection.approvalMode = NewSessionAdapter.approvalMode(
          option, agent: form.selectedAgent(creation))
      },
      togglePlan: form.planToggle(creation), isPlanOn: form.isPlanOn,
      createAgent: agentAction(creation) { isCreatingAgent = true },
      importAgentBundle: agentAction(creation) { isImportingBundle = true })
  }

  /// `action` when agents can be installed here: the server reports `agent_install` and the
  /// session starts on a host (a managed sandbox has no create path for an uploaded bundle).
  private func agentAction(
    _ creation: CreationStore, _ action: @escaping @MainActor () -> Void
  ) -> (@MainActor () -> Void)? {
    !form.isSandbox && creation.catalog.value?.agentInstall == true ? action : nil
  }

  /// "Use This Mac" for this server, where the edition can run hosts.
  private var useThisMachineHere: (@MainActor () async -> String?)? {
    guard let useThisMachine, let url = URL(string: serverURLText) else { return nil }
    return { await useThisMachine(url) }
  }

  private func optionActions(_ creation: CreationStore) -> NewSessionOptionActions {
    let form = form
    return NewSessionOptionActions(
      selectFolder: { path in form.selectFolder(creation, path) },
      browse: { path in
        let hostID = form.selection.hostId
        return await creation.directory(hostID: hostID, path: path)
          .map(NewSessionAdapter.listing)
          .mapError { FolderBrowseError(message: $0.message) }
      },
      selectWorktree: { choice in
        form.worktree = choice
        form.applyWorktree()
      },
      isValidBranch: { isValidBranchName(name: $0) },
      setRepositories: { form.repositories = $0 },
      setUpHarness: {
        guard let harness = form.setupHarness(creation) else { return }
        if harnessSetup == nil { harnessSetup = connection.harnessSetup() }
        Task { await harnessSetup?.load() }
        setupTarget = HarnessSetupTarget(harness: harness, hostID: form.selection.hostId)
      })
  }
}
