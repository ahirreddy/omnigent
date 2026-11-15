import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The Add nested agent composer's source, read fresh when it opens, and the page's copy.
struct NestedComposer: Equatable {
  /// What the page shows: a notice in place of the composer, or the composer for the source.
  enum Phase: Equatable {
    /// The capability or the source is still loading.
    case loading
    /// The server doesn't offer nested agents.
    case unavailable
    /// The source could not be read.
    case sourceUnavailable
    /// The source, as read.
    case ready(OmnigentCoreFFI.SessionSummary)
  }

  static let heading = "Add nested agent"
  static let placeholder = "What should this agent work on?"
  static let unavailableText = "Nested agents are not available on this server."
  static let loadingText = "Loading source session\u{2026}"
  static let sourceUnavailableText = "Source session is unavailable."
  static let continueTitle = "Continue in a new session"
  static let setupNotice =
    "Session created, but setup didn't finish. Open the session to continue."

  /// The session the new one starts beside.
  let sourceID: String
  var phase = Phase.loading
  /// The token of the next create, which ties the provisional row to the row the server sends.
  var token = CreationStore.newCreateToken()

  /// The source, once read.
  var source: OmnigentCoreFFI.SessionSummary? {
    if case .ready(let source) = phase { return source }
    return nil
  }

  /// The source's host: preselected, and always allowed.
  var sourceHostID: String? { source?.configuration?.hostId }

  /// What the page says in place of the composer until the source is read.
  var notice: String {
    switch phase {
    case .unavailable: Self.unavailableText
    case .sourceUnavailable: Self.sourceUnavailableText
    case .loading, .ready: Self.loadingText
    }
  }

  /// "A new conversation alongside <title>".
  var subtitle: String? {
    source.map { "A new conversation alongside \(Self.title(of: $0))" }
  }

  /// The source's title, or "Untitled" as the web says it.
  static func title(of source: OmnigentCoreFFI.SessionSummary) -> String {
    let title = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty || title == "Untitled session" ? "Untitled" : title
  }
}

extension NewSessionForm {
  /// The selection a start sends: routing only with an agent the server routes, and the
  /// approval mode the composer shows.
  func startingSelection(_ creation: CreationStore) -> OmnigentCoreFFI.CreationSelection {
    var selection = selection
    // Routing stays chosen across agents but goes only with one the server routes.
    selection.smartRouting = smartRouting(creation.catalog.value) == .enabled
    // The mode shown is the mode asked for: with none, the harness's own config decides.
    if selection.approvalMode == nil, let agent = selectedAgent(creation) {
      selection.approvalMode = creationApprovalModeMenu(agent: agent)?.selected
    }
    return selection
  }

  /// The heading: a nested agent's, the project's name, else the web's question.
  var heading: String {
    nested != nil ? NestedComposer.heading : project?.name ?? NewSessionPage.defaultHeading
  }

  /// Opens the composer beside its source: the catalog again for the server's current policy,
  /// then the source, whose host and folder are preselected.
  func loadNested(_ creation: CreationStore) async {
    guard let sourceID = nested?.sourceID else { return }
    // A nested agent never defaults to a new sandbox or the last host used.
    didDefaultToSandbox = true
    await creation.loadCatalog()
    if creation.catalog.value?.siblingSessions == false {
      nested?.phase = .unavailable
      return
    }
    switch await creation.nestedSource(sourceID) {
    case .success(let source):
      guard nested?.sourceID == sourceID else { return }
      nested?.phase = .ready(source)
      snapToSource(creation)
      if let catalog = creation.catalog.value { applyDefaults(catalog) }
      await reloadChoices(creation, selection)
    case .failure:
      nested?.phase = .sourceUnavailable
    }
  }

  /// What the server's policy offers the composer for its source.
  func nestedChoices(_ creation: CreationStore) -> NestedHostChoices? {
    guard let nested, nested.source != nil, let catalog = creation.catalog.value else {
      return nil
    }
    return nestedHostChoices(catalog: catalog, sourceHostId: nested.sourceHostID)
  }

  /// Back on the source's host and in its folder, with no worktree: as the composer opens, and
  /// when the policy no longer offers what was chosen.
  func snapToSource(_ creation: CreationStore) {
    guard let nested, let source = nested.source, let hostID = nested.sourceHostID else {
      return
    }
    isSandbox = false
    hostWasChosen = true
    if hostID != selection.hostId { selection.hostId = hostID }
    folder = ""
    worktree = .none
    seededFolderHost = hostID
    applyWorktree()
    if source.workspace.hasPrefix("/") {
      selectFolder(creation, source.workspace)
    }
  }

  /// A host or new sandbox the policy stopped offering snaps back to the source's.
  func enforceNestedPolicy(_ creation: CreationStore) {
    guard let choices = nestedChoices(creation) else { return }
    let allowed =
      isSandbox ? choices.offersNewSandbox : choices.hostIds.contains(selection.hostId)
    guard !allowed else { return }
    snapToSource(creation)
    let selection = selection
    Task { await reloadChoices(creation, selection) }
  }

  /// The folder on `hostID` in a nested composer: the source's on its own host, none elsewhere.
  /// - Returns: Whether the composer is nested, so nothing else fills the folder.
  func seedNestedFolder(_ creation: CreationStore, hostID: String) -> Bool {
    guard let nested else { return false }
    if hostID == nested.sourceHostID, let source = nested.source,
      source.workspace.hasPrefix("/")
    {
      seededFolderHost = hostID
      selectFolder(creation, source.workspace)
    }
    return true
  }

  /// Starts the nested agent beside the source, on its host or a new sandbox; never in a
  /// project of its own (the server files it in the source's).
  func startNested(_ creation: CreationStore, text: String) {
    guard let nested, nested.source != nil else { return }
    if !selection.agentId.isEmpty, selection.agentId != Self.pendingAgentID {
      preferences.set(selection.agentId, forKey: DefaultsKey.agent)
    }
    var selection = startingSelection(creation)
    selection.projectId = nil
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = NestedSource(
      sessionID: nested.sourceID, hostID: nested.sourceHostID, token: nested.token)
    if isSandbox {
      let target = sandbox.target(creation.catalog.value)
      Task {
        await creation.createNestedInSandbox(
          selection, target: target, beside: source, title: title, firstMessage: text)
      }
    } else {
      Task {
        await creation.createNested(selection, beside: source, title: title, firstMessage: text)
      }
    }
  }

  /// A refused create: the next one goes out under a new token.
  func nestedCreateFailed() {
    nested?.token = CreationStore.newCreateToken()
  }
}
