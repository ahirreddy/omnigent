import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// What the new-session page starts with, as the web's New Chat dialog: the host and agent used
/// last (when still offered), and on each host its most recent session's folder, else the
/// host's home folder.
extension NewSessionForm {
  /// Where the last start's choices are kept.
  enum DefaultsKey {
    static let host = "omnigent:new-session:last-host"
    static let agent = "omnigent:new-session:last-agent"
    static let sandboxProvider = "omnigent:new-session:last-sandbox-provider"
    static let sandboxProfile = "omnigent:new-session:last-sandbox-profile"
  }

  /// The remembered host, when the catalog still lists it.
  func rememberedHost(_ catalog: OmnigentCoreFFI.CreationCatalog) -> String? {
    guard let id = preferences.string(forKey: DefaultsKey.host) else { return nil }
    return catalog.hosts.contains { $0.hostId == id && $0.isAvailable } ? id : nil
  }

  /// The remembered agent, when the catalog still lists it.
  func rememberedAgent(_ catalog: OmnigentCoreFFI.CreationCatalog) -> String? {
    guard let id = preferences.string(forKey: DefaultsKey.agent) else { return nil }
    return catalog.agents.contains { $0.id == id } ? id : nil
  }

  /// Starts on a new sandbox, once, when the last session started on one or no machine is
  /// online: an offline machine, as a stopped sandbox's is, can start nothing.
  func defaultToSandbox(_ catalog: OmnigentCoreFFI.CreationCatalog) {
    guard !didDefaultToSandbox else { return }
    didDefaultToSandbox = true
    let offered = sandboxProviderOptions(catalog: catalog)
    guard !hostWasChosen, !isSandbox, !startsPendingAgent, !offered.isEmpty,
      rememberedHost(catalog) == nil
    else { return }
    let last = preferences.string(forKey: DefaultsKey.sandboxProvider)
    guard last != nil || !catalog.hosts.contains(where: \.isAvailable) else { return }
    let option = offered.first { ($0.provider ?? "") == last } ?? offered[0]
    sandbox.provider = option.provider
    isSandbox = true
  }

  /// Reloads what `selection` can choose from: a machine's folders and the agent's models on
  /// it, or, for a new sandbox, the models its provider previews for the agent.
  func reloadChoices(
    _ creation: CreationStore, _ selection: OmnigentCoreFFI.CreationSelection
  ) async {
    guard isSandbox else {
      await creation.selectionChanged(selection)
      return
    }
    let catalog = creation.catalog.value
    await creation.selectionChanged(
      selection,
      sandbox: NewSandboxChoice(
        provider: sandbox.option(catalog)?.provider ?? catalog?.defaultSandboxProvider))
  }

  /// Chooses the sandbox's profile when none is chosen and the provider's are loaded, so a
  /// session can start without visiting the picker: the one used last, else an x86 one, else
  /// the first.
  func defaultSandboxProfile(_ catalog: OmnigentCoreFFI.CreationCatalog?) {
    guard isSandbox, sandbox.profile == nil,
      let offered = sandbox.profilesState(catalog, sandboxes: sandboxes)?.profiles
    else { return }
    sandbox.profile = SandboxChoices.defaultProfile(
      offered, last: preferences.string(forKey: DefaultsKey.sandboxProfile))
  }

  /// Keeps this start's host (or sandbox provider) and agent for the next new session. Only
  /// the kind started on last is kept, so the next page opens on it.
  func rememberChoices() {
    if isSandbox {
      preferences.set(sandbox.provider ?? "", forKey: DefaultsKey.sandboxProvider)
      if let profile = sandbox.profile {
        preferences.set(profile.id, forKey: DefaultsKey.sandboxProfile)
      }
      preferences.removeObject(forKey: DefaultsKey.host)
    } else if !selection.hostId.isEmpty {
      preferences.set(selection.hostId, forKey: DefaultsKey.host)
      preferences.removeObject(forKey: DefaultsKey.sandboxProvider)
    }
    if !selection.agentId.isEmpty, selection.agentId != Self.pendingAgentID {
      preferences.set(selection.agentId, forKey: DefaultsKey.agent)
    }
  }

  /// The folder a new session on `hostID` starts in: its most recent session's folder there.
  static func recentFolder(hostID: String, sessions: [OmnigentCoreFFI.SessionSummary]) -> String? {
    sessions
      .filter { $0.configuration?.hostId == hostID && $0.workspace.hasPrefix("/") }
      // The id settles a tie, so the choice doesn't depend on the order of the list.
      .max { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }?
      .workspace
  }

  /// What refills the folder: another host, the host coming online, leaving a new sandbox, or the
  /// session list being read.
  func folderSeedTrigger(_ creation: CreationStore, list: SessionListStore) -> String {
    let isOnline = creation.catalog.value?.hosts.contains {
      $0.hostId == selection.hostId && $0.isAvailable
    }
    return "\(selection.hostId)/\(isOnline == true)/\(isSandbox)/\(Self.hasRead(list))"
  }

  /// The list has answered, so a host with no sessions in it really has none.
  private static func hasRead(_ list: SessionListStore) -> Bool {
    list.isLoaded || list.lastError != nil
  }

  /// Fills an empty folder once per host: the host's recent folder, else its home folder. Reads
  /// every session, since the sidebar's search and quick filter say nothing about the host.
  func seedFolder(_ creation: CreationStore, list: SessionListStore) async {
    let hostID = selection.hostId
    guard !isSandbox, folder.isEmpty, !hostID.isEmpty, seededFolderHost != hostID,
      Self.hasRead(list)
    else { return }
    if seedNestedFolder(creation, hostID: hostID) { return }
    let sessions = filterSessions(
      sessions: Array(list.sessionsByID.values), text: "", filter: .all)
    if let recent = Self.recentFolder(hostID: hostID, sessions: sessions) {
      seededFolderHost = hostID
      selectFolder(creation, recent)
      return
    }
    // The home listing's own path. A host that can't list it, as one still offline, tries again
    // when it comes online.
    if case .success(let home) = await creation.directory(hostID: hostID, path: nil),
      let path = home.path, folder.isEmpty, selection.hostId == hostID
    {
      seededFolderHost = hostID
      selectFolder(creation, path)
    }
  }
}
