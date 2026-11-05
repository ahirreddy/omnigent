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
    if selection.hostId.isEmpty {
      let host = catalog.hosts.first(where: \.isAvailable) ?? catalog.hosts.first
      selection.hostId = rememberedHost(catalog) ?? host?.hostId ?? ""
    }
    if selection.agentId.isEmpty {
      let ordered = NewSessionAdapter.agents(catalog, hostID: selection.hostId).choices
      selection.agentId =
        rememberedAgent(catalog)
        ?? ordered.first { $0.unavailableReason == nil }?.id ?? ordered.first?.id ?? ""
    }
    await creation.selectionChanged(selection)
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
    change(creation) {
      $0.agentId = agentID
      $0.model = nil
      $0.reasoningEffort = nil
      $0.approvalMode = nil
      $0.planMode = false
    }
  }

  /// Reloads hosts and agents after a setup, an install or a new host, keeping the selection.
  func reloadCatalog(_ creation: CreationStore) async {
    await creation.loadCatalog()
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
