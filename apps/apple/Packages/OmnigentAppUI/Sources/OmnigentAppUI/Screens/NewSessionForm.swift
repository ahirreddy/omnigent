import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import UniformTypeIdentifiers

/// The new-session page's choices: the core's selection, the folder and worktree, a new
/// sandbox with its repositories, and the last attachment that could not be read.
@Observable
final class NewSessionForm {
  /// Host, agent, workspace, model, effort, approval and Plan mode.
  var selection = OmnigentCoreFFI.CreationSelection(
    hostId: "", agentId: "", workspace: "", model: nil)
  /// The folder the user chose; the workspace differs when starting in an existing worktree.
  var folder = ""
  /// Where in the folder's repository the session works.
  var worktree = NewSessionWorktreeChoice.none
  /// The branch Settings › Git's "Always use a random worktree" chose, and for which folder.
  @ObservationIgnored var worktreeSeed: WorktreeSeed?
  /// Where Settings › Git's worktree defaults and the last start's choices are saved.
  @ObservationIgnored var preferences = UserDefaults.standard
  /// The host whose folder was filled in, so a later change of folder is kept.
  @ObservationIgnored var seededFolderHost: String?
  /// The session starts on a new sandbox.
  var isSandbox = false
  /// The sandbox's provider, repositories and profile.
  var sandbox = SandboxChoices()
  /// The sandbox reads (profiles, GitHub repositories).
  @ObservationIgnored var sandboxes: SandboxStore?
  /// A custom agent created on this page and not saved: it uploads with the session.
  var pendingAgent: OmnigentCoreFFI.AgentDraft?
  /// The user picked the host, so it stays when another comes online.
  @ObservationIgnored var hostWasChosen = false
  /// The user picked the agent, so it stays when it isn't ready on a host.
  @ObservationIgnored var agentWasChosen = false
  /// The project the session is filed in.
  var project: ProjectSummary?
  /// Why the project's defaults could not be read.
  var projectError: String?
  /// The session last filed in a label-only project, so a retried send does not move it again.
  @ObservationIgnored var filedSessionID: String?
  /// A picked file that could not be read.
  var attachmentError: String?

  /// The selected agent in `creation`'s catalog.
  func selectedAgent(_ creation: CreationStore?) -> OmnigentCoreFFI.CreationAgent? {
    pendingCreationAgent ?? creation?.catalog.value?.agents.first { $0.id == selection.agentId }
  }

  /// Picks the first available host and agent once the catalog loads, then loads their folders
  /// and models.
  func load(_ creation: CreationStore) async {
    if creation.catalog.value == nil { await creation.loadCatalog() }
    guard let catalog = creation.catalog.value else { return }
    applyDefaults(catalog)
    await creation.selectionChanged(selection)
  }

  /// Fills what the user hasn't chosen: an online host, then an agent ready on it. Runs again as
  /// hosts change, since one can connect after the page opened with none to judge agents by.
  func applyDefaults(_ catalog: OmnigentCoreFFI.CreationCatalog) {
    let isOnline = catalog.hosts.contains { $0.hostId == selection.hostId && $0.isAvailable }
    if !hostWasChosen, !isOnline {
      let host = catalog.hosts.first(where: \.isAvailable) ?? catalog.hosts.first
      let next = rememberedHost(catalog) ?? host?.hostId ?? selection.hostId
      if !selection.hostId.isEmpty, next != selection.hostId { forgetFolder() }
      selection.hostId = next
    }
    guard !agentWasChosen, !startsPendingAgent else { return }
    let agent = defaultAgent(catalog)
    if agent != selection.agentId { resetAgent(agent, in: &selection) }
  }

  /// The remembered agent or else the first one ready on the host; with none ready, the agent
  /// to set up.
  private func defaultAgent(_ catalog: OmnigentCoreFFI.CreationCatalog) -> String {
    let ordered = NewSessionAdapter.agents(catalog, hostID: selection.hostId).choices
    let ready = ordered.filter { $0.unavailableReason == nil }.map(\.id)
    let remembered = rememberedAgent(catalog)
    if let remembered, ready.contains(remembered) { return remembered }
    if let first = ready.first { return first }
    if let remembered { return remembered }
    if ordered.contains(where: { $0.id == selection.agentId }) { return selection.agentId }
    return ordered.first?.id ?? ""
  }

  /// The user picked `hostID`; an agent they didn't pick follows what is ready there.
  func chooseHost(_ hostID: String, _ creation: CreationStore) {
    hostWasChosen = true
    if hostID != selection.hostId {
      forgetFolder()
      Task { await creation.folderChanged(hostID: hostID, path: "") }
    }
    selection.hostId = hostID
    if let catalog = creation.catalog.value { applyDefaults(catalog) }
    let selection = selection
    Task { await creation.selectionChanged(selection) }
  }

  /// The Host menu's row: a new sandbox of a provider, or a machine. Picking the machine already
  /// selected keeps its folder and worktree.
  func chooseHostRow(_ rowID: String, _ creation: CreationStore) {
    if let provider = NewSessionAdapter.sandboxProvider(hostID: rowID) {
      if sandbox.provider != provider { sandbox.profile = nil }
      sandbox.provider = provider
      isSandbox = true
    } else {
      isSandbox = false
      chooseHost(rowID, creation)
    }
  }

  /// Edits the selection and reloads the host's folders and the agent's models.
  func change(
    _ creation: CreationStore, _ edit: (inout OmnigentCoreFFI.CreationSelection) -> Void
  ) {
    edit(&selection)
    let selection = selection
    Task { await creation.selectionChanged(selection) }
  }

  /// Models, efforts and launch modes belong to the agent: a new agent starts on its defaults.
  func selectAgent(_ agentID: String, _ creation: CreationStore) {
    agentWasChosen = true
    change(creation) { resetAgent(agentID, in: &$0) }
  }

  private func resetAgent(_ agentID: String, in selection: inout OmnigentCoreFFI.CreationSelection)
  {
    selection.agentId = agentID
    selection.model = nil
    selection.reasoningEffort = nil
    selection.approvalMode = nil
    selection.planMode = false
  }

  static let hostCheckInterval = Duration.seconds(2)

  /// Reloads hosts and agents after a setup, an install or a new host, keeping what the user
  /// chose.
  func reloadCatalog(_ creation: CreationStore) async {
    await creation.loadCatalog()
    if let catalog = creation.catalog.value { applyDefaults(catalog) }
    await creation.selectionChanged(selection)
  }

  /// A new or imported agent: reload the catalog and select it.
  func agentInstalled(_ agent: OmnigentCoreFFI.ManagedAgent, _ creation: CreationStore) async {
    await creation.loadCatalog()
    selectAgent(agent.id, creation)
  }

  /// A new folder starts in the folder itself and reloads its repository's worktrees.
  func selectFolder(_ creation: CreationStore, _ path: String) {
    folder = path
    worktree = .none
    applyWorktree()
    let hostID = selection.hostId
    Task { await creation.folderChanged(hostID: hostID, path: path) }
  }

  /// Applies the worktree choice to the selection's git block and workspace.
  /// A folder is a path on one machine: on leaving the host, the next one fills its own.
  private func forgetFolder() {
    folder = ""
    worktree = .none
    seededFolderHost = nil
    applyWorktree()
  }

  func applyWorktree() {
    let resolved = NewSessionAdapter.git(worktree, folder: folder)
    selection.git = resolved.git
    selection.workspace = resolved.workspace
  }

  /// Creates the session on the chosen host or a new sandbox and sends `text`.
  func start(_ creation: CreationStore, text: String) {
    rememberChoices()
    var selection = selection
    // A first-class project files the session at creation; a label-only one is moved after.
    selection.projectId = project?.id
    // Routing stays chosen across agents but goes only with one the server routes.
    selection.smartRouting = smartRouting(creation.catalog.value) == .enabled
    // The mode shown is the mode asked for: with none, the harness's own config decides.
    if selection.approvalMode == nil, let agent = selectedAgent(creation) {
      selection.approvalMode = creationApprovalModeMenu(agent: agent)?.selected
    }
    if isSandbox {
      let target = sandbox.target(creation.catalog.value)
      Task {
        await creation.createInSandbox(selection, target: target, title: "", firstMessage: text)
      }
    } else if let draft = pendingAgent, selection.agentId == Self.pendingAgentID {
      Task { await creation.create(agent: draft, selection, firstMessage: text) }
    } else {
      Task { await creation.create(selection, title: "", firstMessage: text) }
    }
  }

  /// The amber "not ready" notice: the selected agent's harness reports a readiness that is
  /// not ready on an online host (offline hosts and unknown agents say so in the context row).
  func harnessNotice(_ creation: CreationStore) -> (text: String, name: String)? {
    guard !isSandbox, !startsPendingAgent, let catalog = creation.catalog.value,
      let agent = selectedAgent(creation),
      let host = catalog.hosts.first(where: { $0.hostId == selection.hostId }),
      host.status == "online", host.sandboxProvider == nil,
      creationUnavailableReason(
        catalog: catalog, agentId: selection.agentId, hostId: selection.hostId) != nil
    else { return nil }
    return ("\(agent.name) isn't ready on \(host.name).", agent.name)
  }

  /// Nothing can run yet: no host is online and no managed sandbox is offered.
  func needsHost(_ creation: CreationStore) -> Bool {
    guard !isSandbox, let catalog = creation.catalog.value else { return false }
    return !catalog.managedSandboxes && !catalog.hosts.contains(where: \.isAvailable)
  }

  /// Checks for a host until one connects, which nothing announces to this screen. Hosts connect
  /// on their own moments after the app opens, and from a command run elsewhere.
  func waitForHost(_ creation: CreationStore) async {
    guard needsHost(creation) else { return }
    while needsHost(creation) {
      do {
        try await Task.sleep(for: Self.hostCheckInterval)
      } catch {
        // Cancelled: the screen left, or a host connected.
        return
      }
      await creation.refreshCatalog()
    }
    if let catalog = creation.catalog.value {
      applyDefaults(catalog)
      await creation.selectionChanged(selection)
    }
  }

  /// The setup sheet's harness: the readiness key the host reports for the selected agent.
  func setupHarness(_ creation: CreationStore) -> String? {
    guard let agent = selectedAgent(creation) else { return nil }
    return agent.harness ?? (agent.harnessId.isEmpty ? nil : agent.harnessId)
  }

  /// Plan mode at launch: Claude Code's `plan` approval mode, or a Codex launch label.
  func planToggle(_ creation: CreationStore) -> (@MainActor () -> Void)? {
    guard !isSandbox, let agent = selectedAgent(creation), let catalog = creation.catalog.value
    else { return nil }
    if creationApprovalModeMenu(agent: agent)?.options.contains(where: { $0.value == "plan" })
      == true
    {
      return { [self] in
        selection.approvalMode = selection.approvalMode == "plan" ? nil : "plan"
      }
    }
    guard creationStartsInPlanMode(catalog: catalog, agentId: agent.id) else { return nil }
    return { [self] in selection.planMode.toggle() }
  }

  /// Plan mode is armed.
  var isPlanOn: Bool {
    selection.approvalMode == "plan" || selection.planMode
  }

  /// The staged files as composer chips.
  func attachmentChips(_ creation: CreationStore) -> [OmnigentUIComponents.DraftAttachment] {
    creation.attachments.map {
      OmnigentUIComponents.DraftAttachment(
        id: $0.id.uuidString, title: $0.filename,
        kind: UTType(mimeType: $0.mediaType ?? "")?.conforms(to: .image) == true ? .image : .file,
        byteCount: Int64($0.data.count))
    }
  }

  /// Reads picked or dropped files and stages them; a file that cannot be read is reported.
  func stage(_ inputs: [ComposerAttachmentInput], in creation: CreationStore) {
    for input in inputs {
      switch input {
      case .file(let url):
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
          let data = try Data(contentsOf: url)
          creation.stageAttachment(
            PendingAttachment(
              filename: url.lastPathComponent,
              mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
              data: data))
        } catch {
          attachmentError = "Could not read \(url.lastPathComponent): \(error.localizedDescription)"
        }
      case .data(let data, let name, let type):
        creation.stageAttachment(
          PendingAttachment(filename: name, mediaType: type.preferredMIMEType, data: data))
      }
    }
  }

  /// The folder, worktree, repository, notice and Plan mode chips under the composer.
  func options(_ creation: CreationStore, projects: [ProjectSummary] = []) -> NewSessionOptions {
    let worktrees = NewSessionAdapter.worktrees(creation.worktrees.value ?? [])
    let notice = harnessNotice(creation)
    var options = NewSessionOptions(
      folder: folder.isEmpty ? nil : folder,
      recentFolders: (creation.workspaces.value ?? []).map(\.path),
      isSandbox: isSandbox,
      repositories: sandbox.repositoriesState(creation.catalog.value, sandboxes: sandboxes),
      profiles: sandbox.profilesState(creation.catalog.value, sandboxes: sandboxes),
      offersWorktrees: !(creation.worktrees.value ?? []).isEmpty, worktrees: worktrees,
      worktree: worktree, harnessNotice: notice?.text, setUpName: notice?.name,
      isPlanMode: isPlanOn, defaultBaseBranch: worktreeDefaults.base)
    options.needsHost = needsHost(creation)
    options.project = project?.name
    options.projects = projects.map(\.name)
    return options
  }

  /// Files a just-created session in a label-only project, which the create cannot name.
  func fileInLabelProject(_ sessionID: String, list: SessionListStore) {
    guard let project, project.id == nil, filedSessionID != sessionID else { return }
    filedSessionID = sessionID
    // The move reports its own failure in the list's edit error.
    Task { _ = await list.move(sessionID, to: project) }
  }
}
