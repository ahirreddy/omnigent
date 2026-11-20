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
/// never repeated, and an unclear outcome blocks until the user acknowledges it. Beside a source
/// session it is the Add nested agent composer.
struct NewSessionContainer: View {
  let connection: ConnectionStore
  let open: @MainActor (String) -> Void
  /// The session a nested agent starts beside; `nil` for a new session.
  let nestedSourceID: String?
  /// Opens a created nested agent whose setup didn't finish, with this notice over it.
  let openWithNotice: (@MainActor (String, String) -> Void)?
  /// Leaves a nested composer for a new session's, which takes the draft.
  let continueInNewSession: (@MainActor () -> Void)?
  /// The project the session is filed in from the start: a project board's composer.
  let project: ProjectSummary?
  /// Only the composer, floated over a project's board.
  let isFloating: Bool
  /// Opens the Workflows page on a workflow, after its planning chat starts or Cancel.
  let openWorkflow: (@MainActor (String) -> Void)?
  /// Offers only this Mac and new sandboxes, as the floating New Agent panel does.
  let onlyThisMachine: Bool

  @State private var draft = ""
  @State private var form: NewSessionForm
  @State private var creation: CreationStore?
  @State private var coreMissing = false
  @State private var setupTarget: HarnessSetupTarget?
  @State private var harnessSetup: HarnessSetupStore?
  @State private var customAgents: CustomAgentsStore?
  @State private var launch: LaunchCompletionsStore?
  @State private var isCreatingAgent = false
  @State private var isImportingBundle = false
  @State private var isConnectingHost = false
  /// Observed so turning Settings › Git's random worktree on or off reseeds the form.
  @AppStorage(GitPreferences.alwaysUseWorktreeKey) private var alwaysUseWorktree = false
  @State private var composerPreferences = StoredComposerPreferences.stored()
  @Environment(\.useThisMachine) private var useThisMachine
  @Environment(\.openURL) private var openURL
  @Environment(\.openSettingsAt) private var openSettingsAt
  @Environment(\.scenePhase) private var scenePhase
  /// MCP sign-in went to the browser: the services are read again on the way back.
  @State private var awaitsMcpSignIn = false

  init(
    connection: ConnectionStore, form: NewSessionForm = NewSessionForm(),
    nestedSourceID: String? = nil, open: @escaping @MainActor (String) -> Void,
    openWithNotice: (@MainActor (String, String) -> Void)? = nil,
    continueInNewSession: (@MainActor () -> Void)? = nil,
    project: ProjectSummary? = nil, isFloating: Bool = false,
    openWorkflow: (@MainActor (String) -> Void)? = nil, onlyThisMachine: Bool = false
  ) {
    self.openWorkflow = openWorkflow
    self.onlyThisMachine = onlyThisMachine
    self.connection = connection
    self.open = open
    self.nestedSourceID = nestedSourceID
    self.openWithNotice = openWithNotice
    self.continueInNewSession = continueInNewSession
    self.project = project
    self.isFloating = isFloating
    _form = State(initialValue: form)
  }

  var body: some View {
    Group {
      if let creation, let nested = form.nested, nested.source == nil {
        NewSessionNotice(
          title: NestedComposer.heading, message: nested.notice,
          isWaiting: nested.phase == .loading,
          action: continueAction(creation, nested).map {
            (title: NestedComposer.continueTitle, run: $0)
          })
      } else if let creation {
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
    .modifier(ComposerPreferencesReader(preferences: $composerPreferences))
    .task {
      guard let creation = connection.creation() else {
        coreMissing = true
        return
      }
      self.creation = creation
      if onlyThisMachine {
        form.limitsMachines = true
        form.allowedMachineIDs = Set(
          [connection.sessionList.thisMachineHostID()].compactMap(\.self))
      }
      customAgents = connection.customAgents()
      launch = connection.launchCompletions()
      form.sandboxes = connection.sandboxes()
      await begin(creation)
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active, awaitsMcpSignIn else { return }
      awaitsMcpSignIn = false
      Task { await creation?.loadMcpServices() }
    }
  }

  private func page(_ creation: CreationStore) -> some View {
    NewSessionPage(
      draft: $draft,
      composer: form.composerState(
        creation, connection: connection, launch: launch,
        submitWithCommandReturn: composerPreferences.submitWithCommandReturn),
      actions: actions(creation),
      // The web's hero: a nested agent's, the project's name, else "What should we build?".
      heading: form.heading(branded: connection.pages?.offered?.branding?.heading),
      subtitle: form.nested?.subtitle ?? form.workflowSubtitle,
      importSessions: importSessions(openURL, openSettingsAt),
      options: form.options(creation, projects: connection.sessionList.projects),
      optionActions: optionActions(creation), isFloating: isFloating,
      workflow: form.workflowControls(clearDraft: { draft = "" }, openWorkflow: openWorkflow)
    )
    .modifier(
      NewSessionLifecycle(
        form: form, creation: creation, connection: connection,
        opened: { opened($0, creation) },
        openedUnfinished: openUnfinished(creation))
    )
    .onChange(of: draft) {
      launch?.draftChanged(draft, target: form.mentionTarget(creation))
      keepNestedDraft(creation)
    }
    .task(id: form.skillsRequest(creation)) {
      let request = form.skillsRequest(creation)
      await launch?.loadSkills(request.target, unavailable: request.unavailable)
    }
    .onChange(of: creation.workflowLaunch) { takeWorkflowLaunch(creation) }
    .onChange(of: creation.worktrees, initial: true) { form.seedWorktree(creation) }
    .onChange(of: alwaysUseWorktree) { form.seedWorktree(creation) }
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
        store: customAgents, allowsImport: creation.catalog.value?.agentInstall == true,
        created: agentCreated(creation),
        drafted: { draft in
          isCreatingAgent = false
          form.adoptPendingAgent(draft)
        },
        cancel: { isCreatingAgent = false })
    }
  }

  /// A bundle the sheet installed becomes the form's agent.
  func agentCreated(_ creation: CreationStore) -> @MainActor (ManagedAgent) -> Void {
    { agent in
      isCreatingAgent = false
      Task { await form.agentInstalled(agent, creation) }
    }
  }

  func actions(_ creation: CreationStore) -> ComposerActions {
    let form = form
    return ComposerActions(
      send: {
        let harness = form.selectedAgent(creation)?.harness
        form.start(creation, text: launch?.message(draft, harness: harness) ?? draft)
      },
      addAttachments: { form.stage($0, in: creation) },
      removeAttachment: { chip in
        if let id = UUID(uuidString: chip.id) { creation.removeAttachment(id) }
      },
      // A model is chosen from the agent's list already read: nothing is read again, so the
      // page never refuses a start while the same list loads a second time.
      selectModel: { model in
        let current = ComposerConfiguration(
          modelOptions: NewSessionAdapter.models(creation.models.value ?? []),
          selectedModelId: form.selection.model, selectedEffort: form.selection.reasoningEffort)
        form.selection.reasoningEffort = current.effortKept(selecting: model)
        form.selection.model = model
      },
      selectEffort: { effort in form.selection.reasoningEffort = effort },
      selectAgent: { agentID in form.selectAgent(agentID, creation) },
      acknowledgeUncertainDelivery: { creation.acknowledgeUncertain() },
      dismissDeliveryError: {
        form.attachmentError = nil
        form.projectError = nil
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

  func extraActions(_ creation: CreationStore) -> ComposerExtraActions {
    let form = form
    // A new agent uploads with the session, so it needs no `agent_install`; importing a bundle
    // installs it. A managed sandbox has no create path for an uploaded bundle.
    var createAgent: (@MainActor () -> Void)?
    var importBundle: (@MainActor () -> Void)?
    // A nested agent starts on a registered agent; a new one would upload as a custom bundle.
    if !form.isSandbox, form.nested == nil {
      createAgent = { isCreatingAgent = true }
      if creation.catalog.value?.agentInstall == true {
        importBundle = { isImportingBundle = true }
      }
    }
    var connectHost: (@MainActor () -> Void)?
    if offersConnectHost(creation) { connectHost = { isConnectingHost = true } }
    var extras = ComposerExtraActions(
      selectHost: { host in form.chooseHostRow(host.id, creation) },
      connectHost: connectHost,
      selectApprovalMode: { option in
        form.selection.approvalMode = option.id
      },
      togglePlan: form.planToggle(creation), isPlanOn: form.isPlanOn,
      createAgent: createAgent, importAgentBundle: importBundle)
    extras.setSmartRouting = { form.selection.smartRouting = $0 }
    if let launch {
      extras.attachMention = { launch.addMention($0) }
      extras.removeMention = { launch.removeMention($0) }
    }
    return extras
  }

  /// "Use This Mac" for this server, where the edition can run hosts.
  private var useThisMachineHere: (@MainActor () async -> String?)? {
    guard let useThisMachine, let url = URL(string: serverURLText) else { return nil }
    return { await useThisMachine(url) }
  }
}

/// The options under the composer: folder, worktree, sandbox, harness setup, MCPs and project.
extension NewSessionContainer {
  func optionActions(_ creation: CreationStore) -> NewSessionOptionActions {
    let form = form
    let list = connection.sessionList
    var actions = NewSessionOptionActions(
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
      repositories: SandboxChoices.repositoryActions(form.sandboxes) { form.sandbox.repos = $0 },
      profiles: SandboxChoices.profileActions(
        form.sandbox.profileProvider(creation.catalog.value), sandboxes: form.sandboxes
      ) { form.sandbox.profile = $0 },
      setUpHarness: {
        guard let harness = form.setupHarness(creation) else { return }
        if harnessSetup == nil { harnessSetup = connection.harnessSetup() }
        Task { await harnessSetup?.load() }
        setupTarget = HarnessSetupTarget(harness: harness, hostID: form.selection.hostId)
      })
    if offersConnectHost(creation) { actions.connectHost = { isConnectingHost = true } }
    actions.setName = { form.name = $0 }
    guard form.nested == nil else { return actions }
    actions.mcpServices = McpLaunchActions(
      toggle: { id, enabled in form.toggleMcpService(id, enabled: enabled) },
      reload: { Task { await creation.loadMcpServices() } })
    if let server = connection.connectedServer, var url = URL(string: server.baseUrl) {
      url.append(path: "settings/mcp")
      actions.mcpServices?.signIn = {
        awaitsMcpSignIn = true
        openURL(url)
      }
    }
    actions.selectProject = { name in
      guard let project = name.flatMap({ name in list.projects.first { $0.name == name } }) else {
        form.project = nil
        return
      }
      Task { await form.applyProject(project, creation) }
    }
    return actions
  }
}

/// Add nested agent: opening beside the source, the source's draft, and what follows a create.
extension NewSessionContainer {
  /// Opens the page: beside its source, with that source's draft, or as a new session with any
  /// draft handed to it.
  private func begin(_ creation: CreationStore) async {
    guard let nestedSourceID else {
      if let handed = creation.composerDrafts.removeValue(forKey: "") { draft = handed }
      takeWorkflowLaunch(creation)
      await form.load(creation)
      if let project { await form.applyProject(project, creation) }
      return
    }
    form.nested = NestedComposer(sourceID: nestedSourceID)
    draft = creation.composerDrafts[nestedSourceID] ?? ""
    await form.loadNested(creation)
  }

  /// A created session opens, except a planning chat: its workflow's page opens with it.
  private func opened(_ sessionID: String, _ creation: CreationStore) {
    let planned = form.planningStarted(
      sessionID, creation: creation, workflows: connection.workflows, openWorkflow: openWorkflow)
    finish(creation)
    if !planned { open(sessionID) }
  }

  /// A workflow the Workflows page asked to run or plan; a planning chat's prompt is the draft.
  private func takeWorkflowLaunch(_ creation: CreationStore) {
    if let prompt = form.takeWorkflowLaunch(creation) { draft = prompt }
  }

  /// Keeps a nested composer's text under its source, so it comes back with the composer.
  private func keepNestedDraft(_ creation: CreationStore) {
    guard let sourceID = form.nested?.sourceID else { return }
    creation.composerDrafts[sourceID] = draft.isEmpty ? nil : draft
  }

  /// A created session takes the draft with it.
  private func finish(_ creation: CreationStore) {
    if let sourceID = form.nested?.sourceID { creation.composerDrafts[sourceID] = nil }
    form.clearWorkflow()
    draft = ""
    launch?.clearMentions()
  }

  /// A nested agent whose create went through but whose setup didn't opens anyway, saying so.
  private func openUnfinished(_ creation: CreationStore) -> (@MainActor (String) -> Void)? {
    guard form.nested != nil, let openWithNotice else { return nil }
    return { sessionID in
      finish(creation)
      openWithNotice(sessionID, NestedComposer.setupNotice)
    }
  }

  /// "Continue in a new session" when the source can't be read: the draft goes along.
  private func continueAction(
    _ creation: CreationStore, _ nested: NestedComposer
  ) -> (@MainActor () -> Void)? {
    guard nested.phase == .sourceUnavailable, let continueInNewSession else { return nil }
    return {
      if !draft.isEmpty { creation.composerDrafts[""] = draft }
      continueInNewSession()
    }
  }

  /// Connect a Host, except where a nested agent's policy keeps it to the source's host.
  private func offersConnectHost(_ creation: CreationStore) -> Bool {
    form.nestedChoices(creation)?.offersConnectHost ?? (form.nested == nil)
  }
}
