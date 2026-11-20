import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

/// What the conversation's alert reports. An object, so closures made in an earlier render add
/// to the same list.
@Observable
final class ConversationFailures {
  var messages: [String] = []
}

extension ConversationContainer {
  /// What the alert reports.
  var failures: [String] {
    get { failureList.messages }
    nonmutating set { failureList.messages = newValue }
  }
}

/// A transcript in the web's `.jsonl` export format, for the save panel.
struct TranscriptExport: FileDocument {
  static let contentType = contentType(forExtension: "jsonl")
  static var readableContentTypes: [UTType] { [contentType] }

  let text: String

  /// The file's bytes.
  var fileContents: Data { Data(text.utf8) }

  init(text: String) {
    self.text = text
  }

  /// A transcript read from a file's bytes.
  init(fileContents: Data?) throws {
    guard let fileContents, let text = String(bytes: fileContents, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.text = text
  }

  /// The system's type for an extension, or JSON where it has none.
  static func contentType(forExtension fileExtension: String) -> UTType {
    UTType(filenameExtension: fileExtension) ?? .json
  }

  /// Reads `conversation`'s whole transcript and hands it to `take`, for the save panel.
  @MainActor
  static func read(
    _ conversation: ConversationStore, into take: @escaping @MainActor (Self) -> Void,
    report: @escaping @MainActor (String) -> Void
  ) {
    Task {
      do throws(CoreError) {
        take(Self(text: try await conversation.exportTranscript()))
      } catch {
        report("Could not export the transcript: \(error.message)")
      }
    }
  }

  /// The save panel closed: a file that couldn't be written is reported.
  @MainActor
  static func finished(_ result: Result<URL, any Error>, report: @MainActor (String) -> Void) {
    if case .failure(let error) = result {
      report("Could not save the transcript: \(error.localizedDescription)")
    }
  }

  // coverage:off only SwiftUI's save panel can make these; the flow testExportSavesTheTranscript
  init(configuration: ReadConfiguration) throws {
    try self.init(fileContents: configuration.file.regularFileContents)
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: fileContents)
  }
  // coverage:on
}

extension ConversationContainer {
  /// The `@` menu over the session's workspace: the browsed folder's files and folders, then
  /// deeper paths that contain the typed filter (`src/ma` browses `src` for `ma`).
  static func mentionSearch(_ workspace: WorkspaceBrowserModel)
    -> @MainActor (String) async throws -> [String]
  {
    let source = workspace.source
    return { query in
      let slash = query.lastIndex(of: "/")
      let folder = slash.map { String(query[..<$0]) } ?? ""
      let filter = slash.map { String(query[query.index(after: $0)...]) } ?? query
      do throws(WorkspaceFailure) {
        let listing = try await source.listDirectory(folder, after: nil).entries
        let matches = filter.isEmpty ? [] : try await source.searchPaths(query).entries
        return ComposerStore.mentionRows(
          query: query, listing: listing.map(mentionEntry), matches: matches.map(mentionEntry))
      } catch {
        throw CoreError.InvalidState(message: error.message)
      }
    }
  }

  private static func mentionEntry(_ entry: OmnigentWorkspaceUI.WorkspaceEntry) -> MentionEntry {
    MentionEntry(path: entry.path, name: entry.name, isDirectory: entry.kind == .directory)
  }

  /// The web's link to one message (`?message=<id>`): a user message by its item id, an answer
  /// by its turn. Live previews have no stable id yet.
  static func messageURL(_ row: OmnigentUIComponents.Row, in session: URL?) -> URL? {
    guard let session, !row.isEphemeral,
      var components = URLComponents(url: session, resolvingAgainstBaseURL: false)
    else { return nil }
    let id = row.role == .user ? row.id : (row.responseId ?? row.id)
    components.queryItems =
      (components.queryItems ?? []).filter { $0.name != "message" }
      + [URLQueryItem(name: "message", value: id)]
    return components.url
  }

  /// The session menu's context from the session list: the viewer's projects, the one the
  /// session is in, whether someone else shared it, and the session that created it. A side
  /// chat, which the list leaves out, links to the session it was forked from.
  static func menuContext(
    _ list: SessionListStore, session: OmnigentCoreFFI.SessionSummary?,
    sideChatOf source: String? = nil
  ) -> SessionMenuContext {
    if let source {
      let title = list.sessionWithoutActivity(source)?.title
      return SessionMenuContext(parent: CreatingSession(id: source, title: title))
    }
    guard let session else { return SessionMenuContext() }
    let groups = list.members(of: [session])
    let projects = list.projects.map { project in
      SessionProject(
        id: project.id ?? "label:\(project.name)", name: project.name, sessionIds: [],
        projectID: project.id, icon: project.icon)
    }
    let current = zip(projects, groups).first { $0.1.contains(session.id) }?.0
    let creator = session.createdBySessionId.map {
      CreatingSession(id: $0, title: list.sessionWithoutActivity($0)?.title)
    }
    let parent = list.parent(of: session.id).map {
      CreatingSession(id: $0, title: list.sessionWithoutActivity($0)?.title)
    }
    return SessionMenuContext(
      projects: projects, projectID: current?.id, isShared: !list.isOwned(session),
      createdBy: creator, parent: parent, branch: session.configuration?.gitBranch)
  }
}

extension ConversationContainer {
  /// The conversation's state around the transcript, with what its header and toolbar show.
  var state: ConversationViewState {
    adorned(ConversationAdapter.screenState(conversation, summary: summary))
  }

  /// `state` with Share's reason, the agent's terminal and its tools and policies.
  func adorned(_ state: ConversationViewState) -> ConversationViewState {
    var state = state
    state.shareUnavailableReason = shareUnavailableReason
    let viewer = ConversationAdapter.viewer(server)
    state.viewerName = viewer
    state.isShared = ConversationAdapter.isShared(
      owner: summary?.owner, viewer: viewer, grants: loadedGrants)
    state.sandbox = SandboxAdapter.state(conversation, environment: hostEnvironment)
    if let terminals { state.terminal = TerminalAdapter.status(terminals.terminals.harness) }
    state.agentInfo = conversation.agentInfo.map {
      OmnigentUIComponents.AgentInfo(name: $0.name, tools: $0.tools, policies: $0.policies)
    }
    return state
  }

  /// The Share sheet over the session's grants, once its store exists.
  func share(over shareStore: ShareStore?) -> (state: ShareViewState, actions: ShareActions)? {
    guard offersShare, let shareStore else { return nil }
    let link = SidebarAdapter.webURL(server: server, sessionID: conversation.sessionID)
    return (
      ShareAdapter.state(shareStore, link: link),
      ShareAdapter.actions(shareStore, openAutomation: openAutomationSharing)
    )
  }

  /// Reads the whole transcript, then asks where to save it.
  func exportTranscript() {
    TranscriptExport.read(conversation, into: { export = $0 }, report: { failures.append($0) })
  }

  /// The save panel closed: a file that couldn't be written goes in the alert.
  func exportFinished(_ result: Result<URL, any Error>) {
    TranscriptExport.finished(result) { failures.append($0) }
  }

  /// The right panel's tabs, open files and "Open new" menu; none where the window shows the
  /// session's panel beside every tab.
  var workspaceSlots: WorkspaceSlots {
    tabRoutes?.windowPanel == nil ? workspaceSlots(routes: toolRoutes) : WorkspaceSlots()
  }

  /// The right panel's content, with a side chat started and failures reported through `routes`.
  func workspaceSlots(routes: SessionToolsAdapter.Routes) -> WorkspaceSlots {
    WorkspacePanelSlots(
      workspace: workspace, panel: panel, terminals: terminals, tabRoutes: tabRoutes,
      terminalNames: terminalNames, permissionLevel: conversation.header?.permissionLevel,
      canEdit: !(conversation.header?.readOnly ?? false),
      newSideChat: SessionToolsAdapter.sideChat(conversation, routes: routes),
      agents: AgentTreeAdapter.panel(conversation, open: routes.openSession),
      tasks: tasksSlot(report: routes.report),
      composer: conversation.composer, report: routes.report
    ).slots
  }

  /// The Tasks tab, read when the panel draws, so the tasks do not redraw the chat.
  func tasksSlot(report: @escaping @MainActor (String) -> Void) -> TasksSlot {
    let (tasks, conversation, summary, workflows) = (tasks, conversation, summary, workflows)
    let (focus, sessionID) = (transcriptFocus, conversation.sessionID)
    let routes = TasksAdapter.Routes(showRow: { focus?.focus($0, in: sessionID) }, report: report)
    return TasksSlot(
      isShown: { TasksAdapter.showsTab(tasks: tasks, conversation: conversation) },
      content: {
        var content = TasksAdapter.content(
          tasks: tasks, conversation: conversation, summary: summary, routes: routes)
        TasksAdapter.addWorkflows(
          to: &content, tasks: tasks, conversation: conversation, summary: summary,
          workflows: workflows)
        return content
      })
  }

  /// The chat's task marker links, pointed at this session; its markers read the tasks.
  var taskMarkerLinks: TaskMarkerLinks {
    TasksAdapter.point(markerLinks, tasks: tasks, conversation: conversation, showTasks: showTasks)
  }

  /// The window loads what its panel shows of this chat's session, so the chat does not.
  var windowLoadsPanel: Bool { tabRoutes?.windowPanel?.isSessionChat == true }

  /// The title menu, the right panel's content, Share and navigation.
  func extras(sharing shareStore: ShareStore?) -> ConversationExtras {
    var extras = ConversationExtras(
      sessionActions: forkable(sessionActions), slots: workspaceSlots, sandbox: sandboxActions,
      share: share(over: shareStore), forkActions: forkActions, navigation: navigation,
      menuContext: menuContext, exportTranscript: exportTranscript,
      shareOpened: { Task { await shareStore?.load() } })
    var liveness = SessionLivenessActions()
    addHostMoves(to: &liveness, sheets: livenessSheets)
    extras.switchHost = liveness.switchHost
    extras.tasksPreview = { [tasks, conversation, summary] in
      TasksAdapter.preview(tasks: tasks, conversation: conversation, summary: summary)
    }
    extras.showTasks = showTasks
    if let panel = tabRoutes?.windowPanel {
      extras.showPanelTab = panel.show
      extras.togglePanel = { [route = panel.chrome.panel] in route.isShown.toggle() }
    }
    return extras
  }

  /// The fork opens as a chat tab next to this one, focused.
  var forkActions: ForkActions {
    forkFlow.actions(open: tabRoutes?.openSession ?? openSession) { failures.append($0) }
  }
}

extension ConversationContainer {
  /// The session's forkable summary, when this app can fork it.
  var forkSource: OmnigentCoreFFI.SessionSummary? {
    guard makeForkStore != nil, let summary, forkUnavailableReason(source: summary) == nil else {
      return nil
    }
    return summary
  }

  /// "Fork from here" on settled assistant messages; when the session can't be forked it stays,
  /// disabled with the reason, as on the web.
  func forkable(_ actions: ConversationActions) -> ConversationActions {
    var actions = actions
    addRecoveryFork(to: &actions)
    guard makeForkStore != nil, let source = summary else { return actions }
    if let reason = forkUnavailableReason(source: source) {
      actions.forkUnavailableReason = reason
      return actions
    }
    actions.forkFrom = { row in
      guard let responseID = ForkAdapter.forkPoint(row) else { return }
      beginFork(
        ForkContext(source: source, upToResponseID: responseID, kind: .fromMessage(rowID: row.id)))
    }
    return actions
  }

  /// Changes the session's agent, or says why that one isn't available.
  func switchHarness(to agentID: String) {
    let composer = conversation.composer
    if let reason = composer.harnessOptions.first(where: { $0.id == agentID })?.unavailableReason {
      failures.append(reason)
      return
    }
    Task { await composer.switchHarness(to: agentID) }
  }

  /// Forks the whole session (the session menu's Fork, the reconnect sheet's way out); `nil`
  /// when this app cannot fork it.
  var forkSession: (@MainActor () -> Void)? {
    guard let source = forkSource else { return nil }
    let context = ForkContext(source: source, upToResponseID: nil, kind: .session)
    return { beginFork(context) }
  }
}
