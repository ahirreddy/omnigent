import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTerminalStores
import OmnigentTerminalUI
import OmnigentUIComponents
import OmnigentWorkspaceUI
import SwiftUI
import UniformTypeIdentifiers

/// One open conversation: `ConversationScreen` over a ``ConversationStore``, failures included.
struct ConversationContainer: View {
  let conversation: ConversationStore
  let summary: OmnigentCoreFFI.SessionSummary?
  let terminals: TerminalStore?
  let workspace: WorkspaceBrowserModel?
  /// The right panel's server data (panel features, pull requests).
  let panel: SessionPanelStore?
  let changedFilesRevision: Int
  let navigation: SessionCommandActions
  let opener: ExternalURLOpener
  let openSession: @MainActor (String) -> Void
  let retry: @MainActor () -> Void
  /// The connected server, for the composer's execution context.
  var server: OmnigentCoreFFI.ConnectedServer?
  /// Opens the session's terminals and side chats as tabs.
  var tabRoutes: ConversationTabRoutes?
  /// The terminals the agent declares, for New Terminal.
  var terminalNames: DeclaredTerminals = .unknown
  /// The session menu's Pin, Archive and the other row actions, as in the sidebar.
  var sessionActions = SessionListActions()
  /// Creates the fork sheet's store; `nil` hides Fork.
  var makeForkStore: (@MainActor () -> ForkStore?)?
  /// Projects and sharing, for the session menu's Move and owner-only items.
  var menuContext = SessionMenuContext()
  /// Creates the Share sheet's store; `nil` hides Share.
  var makeShareStore: (@MainActor () -> ShareStore?)?
  /// The server shares sessions, or turned sharing off (multi-user); `false` hides Share.
  var offersShare = true
  /// Why Share shows disabled (sharing turned off on this server).
  var shareUnavailableReason: String?

  /// The right panel once this chat shows or hides it; until then the default it opened with.
  @State private var panelChoice: WorkspacePanelDefault?
  @State private var panelDefault = WorkspacePanelDefault.stored()
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  @State private var inspectorTab: InspectorTab = DefaultWorkspaceTab.stored().inspectorTab
  @State private var showsGoal = false
  @State private var modeRoute = ConversationModeRoute()
  @State private var textSource = ComposerTextSource()
  @State private var isStopping = false
  @State private var dismissedSendError: CoreError?
  @State private var failures: [String] = []
  @State private var harnessSurface: TerminalSurfaceController?
  @State private var forkFlow = ForkFlow()
  @State private var export: TranscriptExport?
  @State private var shareStore: ShareStore?
  @AppStorage(ComposerPreferences.submitWithCommandReturnKey) private var submitWithCommandReturn =
    false
  @AppStorage(ComposerPreferences.alwaysSteerKey) private var alwaysSteer = true
  @State private var fileLinks: WorkspaceFileLinks?
  /// The liveness row's open sheet; a send can open Resume on a Machine.
  @State private var livenessSheets = SessionLivenessSheets()

  var body: some View {
    let composer = conversation.composer
    let screen = state
    ConversationScreen(
      state: screen, composer: composerState(screen),
      draft: textSource.draft(conversation.composer, $textSource),
      showsInspector: showsInspector, inspectorTab: $inspectorTab,
      mode: modeRoute.mode(tabRoutes?.openHarness, $modeRoute),
      fork: $forkFlow.sheet,
      actions: routed(forkable(actions)), composerActions: composerActions,
      extras: ConversationExtras(
        sessionActions: forkable(sessionActions), slots: workspaceSlots,
        share: share, forkActions: forkActions, navigation: navigation,
        menuContext: menuContext, exportTranscript: exportTranscript,
        shareOpened: { [shareStore] in Task { await shareStore?.load() } }),
      liveRows: ConversationAdapter.liveRows(conversation)
    ) {
      harnessTerminal
    }
    .modifier(MessageMediaEnvironment(fileLinks: fileLinks, conversation: conversation))
    .task(id: workspace.map(ObjectIdentifier.init)) {
      fileLinks = workspace.map(MarkdownLinksAdapter.links)
    }
    .fileExporter(
      isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
      document: export, contentType: TranscriptExport.contentType,
      defaultFilename: "\(conversation.sessionID).jsonl"
    ) { result in
      if case .failure(let error) = result {
        failures.append("Could not save the transcript: \(error.localizedDescription)")
      }
    }
    .alert(
      "Something Went Wrong", isPresented: .constant(!failures.isEmpty),
      actions: { Button("OK") { failures = [] } },
      message: { Text(failures.joined(separator: "\n")) }
    )
    .task {
      if shareStore == nil { shareStore = makeShareStore?() }
      composer.searchMentions = workspace.map(Self.mentionSearch)
      await composer.loadConfiguration()
      if let agentID = composer.configuration?.agentId {
        await conversation.loadAgentInfo(agentID: agentID)
      }
      await composer.loadSkills()
    }
    // Reads the features too; the composer tray links the session's pull requests.
    .task { await panel?.reloadPullRequests() }
    .modifier(
      SessionGoalPresenter(
        conversation: conversation, summary: summary, isPresented: $showsGoal,
        report: { failures.append($0) })
    )
    .onChange(of: conversation.isRunning) { _, running in
      Task { await composer.drainQueue(isRunning: running) }
      if !running { Task { await panel?.refreshPullRequestsIfShown() } }
    }
    .onChange(of: terminals?.terminals.harness, initial: true) { attachHarness() }
    .modifier(WorkspacePanelDefaults(workspace: workspace, choice: $panelChoice))
    #if DEBUG
      .modifier(
        PerfConversationHooks(
          showsInspector: showsInspector, inspectorTab: $inspectorTab,
          openBrowser: tabRoutes?.openBrowser, openSideChat: tabRoutes?.openNewSideChat))
    #endif
    .onChange(of: changedFilesRevision) {
      guard let workspace else { return }
      Task { await workspace.changedFilesInvalidated() }
    }
  }

  /// Whether the right panel shows: the chat's choice, else the default where it is a column.
  private var showsInspector: Binding<Bool> {
    #if os(iOS)
      let isSheet = sizeClass == .compact
    #else
      let isSheet = false
    #endif
    let shown = panelChoice.map { $0 == .open } ?? panelDefault.showsPanel(isSheet: isSheet)
    return Binding(get: { shown }, set: { panelChoice = $0 ? .open : .collapsed })
  }

  private var state: ConversationViewState {
    var state = ConversationAdapter.screenState(conversation, summary: summary)
    state.shareUnavailableReason = shareUnavailableReason
    if let terminals { state.terminal = TerminalAdapter.status(terminals.terminals.harness) }
    state.agentInfo = conversation.agentInfo.map {
      OmnigentUIComponents.AgentInfo(name: $0.name, tools: $0.tools, policies: $0.policies)
    }
    return state
  }

  private func composerState(_ screen: ConversationViewState) -> ComposerViewState {
    var composer = ComposerAdapter.state(
      conversation, isStopping: isStopping, dismissedError: dismissedSendError, server: server,
      submitWithCommandReturn: submitWithCommandReturn)
    composer.prefersSteer = alwaysSteer
    if conversation.header?.settings?.sideChatSourceId != nil {
      composer.placeholder = SideChatCopy.placeholder
    }
    let indicators = SessionToolsAdapter.indicators(conversation, screen: screen)
    let pullRequest = SessionToolsAdapter.pullRequestLabel(panel)
    if !indicators.isEmpty || pullRequest != nil {
      var tray = composer.tray ?? ComposerTray()
      tray.indicators = indicators
      SessionToolsAdapter.setPullRequests(panel, label: pullRequest, on: &tray)
      composer.tray = tray
    }
    return composer
  }

  /// What the Add menu and the tray's indicators open.
  private var toolRoutes: SessionToolsAdapter.Routes {
    SessionToolsAdapter.Routes(
      openSession: tabRoutes?.openSession ?? openSession,
      openNewSideChat: tabRoutes?.openNewSideChat,
      showPullRequests: {
        inspectorTab = .pullRequests
        panelChoice = .open
      },
      showGoal: {
        showsGoal = true
        Task { await conversation.tools.loadGoal() }
      },
      report: { failures.append($0) })
  }

  /// The Share sheet over the session's grants, once its store exists.
  private var share: (state: ShareViewState, actions: ShareActions)? {
    guard offersShare, let shareStore else { return nil }
    let link = SidebarAdapter.webURL(server: server, sessionID: conversation.sessionID)
    return (ShareAdapter.state(shareStore, link: link), ShareAdapter.actions(shareStore))
  }

  /// Reads the whole transcript, then asks where to save it.
  private func exportTranscript() {
    let conversation = conversation
    Task {
      do throws(CoreError) {
        export = TranscriptExport(text: try await conversation.exportTranscript())
      } catch {
        failures.append("Could not export the transcript: \(error.message)")
      }
    }
  }

  /// Attaches the harness TUI once ready (the store keeps it), applying the default view.
  private func attachHarness() {
    guard let terminals else { return }
    if terminals.terminals.harness != .notTerminalFirst { tabRoutes?.applyDefaultView?() }
    harnessSurface = terminals.harnessController(
      permissionLevel: conversation.header?.permissionLevel,
      hostID: conversation.header?.settings?.hostId)
  }

  /// The harness TUI when the core reports it ready, else the package's placeholder.
  @ViewBuilder private var harnessTerminal: some View {
    if let harnessSurface {
      SessionTerminalView(controller: harnessSurface)
    } else {
      VStack {
        TerminalPlaceholderView(harness: conversation.header?.settings?.harness)
        if let terminals, let error = terminals.lastError {
          Label(String(describing: error), systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
        }
      }
    }
  }

  /// The right panel's tabs, open files and "Open new" menu.
  private var workspaceSlots: WorkspaceSlots {
    WorkspacePanelSlots(
      workspace: workspace, panel: panel, terminals: terminals, tabRoutes: tabRoutes,
      terminalNames: terminalNames, permissionLevel: conversation.header?.permissionLevel,
      canEdit: !(conversation.header?.readOnly ?? false),
      newSideChat: SessionToolsAdapter.sideChat(conversation, routes: toolRoutes),
      agents: AgentTreeAdapter.panel(conversation, open: tabRoutes?.openSession ?? openSession),
      composer: conversation.composer,
      report: { failures.append($0) }
    ).slots
  }

  /// Side questions open in their own tab; sub-agents and the "Back to the parent session"
  /// capsule open or focus their session's chat tab next to this one.
  private func routed(_ actions: ConversationActions) -> ConversationActions {
    var actions = actions
    if let tabRoutes {
      actions.openSideChat = { row in
        tabRoutes.openSideChat(row.id, row.activity?.detail("question"))
      }
      actions.openChild = tabRoutes.openChild ?? tabRoutes.openSession
      actions.openSession = tabRoutes.openSession
    }
    SessionToolsAdapter.addSelectionActions(to: &actions, store: conversation, routes: toolRoutes)
    return actions
  }

  /// The session menu's Fork copies the whole session.
  private func forkable(_ actions: SessionListActions) -> SessionListActions {
    var actions = actions
    if let fork = forkSession { actions.fork = { _ in fork() } }
    return actions
  }

  func beginFork(_ context: ForkContext) {
    guard let makeForkStore else { return }
    Task { await forkFlow.begin(context, makeStore: makeForkStore) }
  }

  /// The fork opens as a chat tab next to this one, focused.
  private var forkActions: ForkActions {
    let flow = forkFlow
    let open = tabRoutes?.openSession ?? openSession
    return flow.withSandboxActions(
      ForkActions(
        forkWith: { choices in
          Task { await flow.fork(choices, open: open, report: { failures.append($0) }) }
        },
        selectionChanged: { agentID, hostID in
          Task { await flow.selectionChanged(agentID: agentID, hostID: hostID) }
        },
        cancel: { flow.cancel() }))
  }
}

extension ConversationContainer {
  private var actions: ConversationActions {
    let conversation = conversation
    let opener = opener
    var actions = ConversationActions(
      openSession: openSession,
      openAttachment: { attachment in
        guard let reference = attachment.reference, let url = URL(string: reference) else {
          return
        }
        open(url, with: opener)
      },
      openURL: { url in open(url, with: opener) },
      respond: { card, response in
        guard let original = conversation.decisions.cards.first(where: { $0.id == card.id })
        else { return }
        Task {
          await conversation.decisions.resolve(
            original, with: OmnigentCoreFFI.DecisionResponse(response))
        }
      },
      dismissError: { conversation.dismissErrors() },
      retry: retry,
      resume: { Task { await conversation.recoverTurn(.resume) } })
    actions.loadOlder = { conversation.loadOlderHistory() }
    actions.openSignIn = openSignIn
    let link = SidebarAdapter.webURL(server: server, sessionID: conversation.sessionID)
    actions.messageURL = { row in Self.messageURL(row, in: link) }
    actions.retryFailedTurn = { row in
      guard let recovery = row.activity?.recovery else { return }
      guard !conversation.isRunning else {
        failures.append("Wait for the current turn to finish before retrying.")
        return
      }
      Task { await conversation.recoverTurn(recovery == .continue ? .continue : .resume) }
    }
    return actions
  }

  private func open(_ url: URL, with opener: ExternalURLOpener) {
    Task {
      if !(await opener.open(url)) { failures.append("Could not open \(url.absoluteString).") }
    }
  }

  private var composerActions: ComposerActions {
    let conversation = conversation
    let composer = conversation.composer
    return ComposerActions(
      send: { [livenessSheets] in if !holdsSendForResume(livenessSheets) { sendDraft() } },
      interrupt: {
        isStopping = true
        Task {
          await conversation.interrupt()
          isStopping = false
        }
      },
      addAttachments: { inputs in
        Task {
          let unreadable = await ComposerAdapter.add(inputs, to: composer)
          failures += unreadable
        }
      },
      removeAttachment: { attachment in
        guard let id = UInt64(attachment.id) else { return }
        composer.removeAttachment(id)
      },
      selectModel: { model in Task { await composer.selectModel(model) } },
      selectEffort: { effort in Task { await composer.selectEffort(effort) } },
      selectAgent: { agentID in switchHarness(to: agentID) },
      acknowledgeUncertainDelivery: { composer.acknowledgeUncertainSend() },
      dismissDeliveryError: {
        dismissedSendError = composer.lastError
        composer.dismissConfigurationError()
      },
      extras: extras)
  }

  private var extras: ComposerExtraActions {
    let conversation = conversation
    var extras = ComposerAdapter.extras(
      conversation.composer, isRunning: { conversation.isRunning }, reconnect: retry,
      prompts: { ComposerAdapter.prompts(conversation) })
    SessionToolsAdapter.add(to: &extras, store: conversation, summary: summary, routes: toolRoutes)
    extras.liveness.fork = forkSession
    addHostMoves(to: &extras.liveness, sheets: livenessSheets)
    return extras
  }

  /// Sends the composer's draft.
  func sendDraft() {
    dismissedSendError = nil
    let (conversation, newSession, routes) = (conversation, sessionActions.newSession, toolRoutes)
    Task {
      await SessionToolsAdapter.send(conversation, newSession: newSession, routes: routes)
    }
  }

  /// Switches the harness when the core allows it; otherwise says why.
  private func switchHarness(to agentID: String) {
    let composer = conversation.composer
    if let reason = composer.harnessOptions.first(where: { $0.id == agentID })?.unavailableReason {
      failures.append(reason)
      return
    }
    Task { await composer.switchHarness(to: agentID) }
  }
}
