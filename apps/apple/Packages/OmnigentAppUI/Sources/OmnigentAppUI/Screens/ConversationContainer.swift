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
  /// The Tasks tab's journal.
  var tasks: SessionTasksStore?
  /// The saved workflows Run a workflow offers, where the server keeps them.
  var workflows: TasksAdapter.Workflows?
  /// The window's message focus, where a task's Show in the chat scrolls.
  var transcriptFocus: TranscriptFocus?
  /// The file changes that reached this chat's workspace, read by ``ChangedFilesFollower`` and
  /// not here.
  let changedFilesRevision: @MainActor () -> Int
  let navigation: SessionCommandActions
  let opener: ExternalURLOpener
  /// Opens a sign-in page: always the system browser, whatever the in-app links setting says,
  /// because identity providers refuse embedded browsers.
  var signInOpener = ExternalURLOpener.system
  let openSession: @MainActor (String) -> Void
  let retry: @MainActor () -> Void
  /// The connected server, for the composer's execution context.
  var server: OmnigentCoreFFI.ConnectedServer?
  /// The server connection's health: while the window's line shows an outage, the composer's
  /// line does not repeat it.
  var connectionHealth: ConnectionHealth?
  /// Where a session on a host runs, for the titlebar's sandbox status.
  var hostEnvironment: @MainActor (String) -> SessionEnvironment? = { _ in nil }
  /// A session's title, for the line over a message another session sent.
  var sessionTitle: @MainActor (String) -> String? = { _ in nil }
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
  /// Opens an automation's page on its share sheet.
  var openAutomationSharing: (@MainActor (String) -> Void)?
  /// The server splits Terminal views (`splittable_terminal_view_ui`).
  var offersTerminalSplit = false
  /// Where sessions' splits are kept.
  var terminalSplits = TerminalSplitRegistry.shared
  /// Connects this Mac as a host, where the edition can; the reconnect sheet's one click.
  @Environment(\.useThisMachine) var useThisMachine
  /// The workspace the window's right panel shows, where a side chat's or sub-agent's file
  /// links open; `nil` opens them in the chat's own workspace.
  var linkedWorkspace: WorkspaceBrowserModel?

  /// The right panel once this chat shows or hides it; until then the default it opened with.
  @State private var panelRoute = ConversationPanelRoute()
  @State private var panelDefault = WorkspacePanelDefault.stored()
  #if os(iOS)
    @Environment(\.horizontalSizeClass) var sizeClass
  #endif
  @Environment(\.openSettingsAt) var openSettingsAt
  @State private var inspectorTab: InspectorTab = DefaultWorkspaceTab.stored().inspectorTab
  @State private var showsGoal = false
  // swiftlint:disable:next private_swiftui_state
  @State var modeRoute = ConversationModeRoute()
  @State private var textSource = ComposerTextSource()
  @State private var isStopping = false
  @State private var dismissedSendError: CoreError?
  // Not private: a test passes its own objects to watch them.
  // swiftlint:disable:next private_swiftui_state
  @State var failureList = ConversationFailures()
  // swiftlint:disable:next private_swiftui_state
  @State var harnessSurface: TerminalSurfaceController?
  // swiftlint:disable:next private_swiftui_state
  @State var forkFlow = ForkFlow()
  // swiftlint:disable:next private_swiftui_state
  @State var export: TranscriptExport?
  @State private var shareStore: ShareStore?
  @State private var composerPreferences = StoredComposerPreferences.stored()
  @State private var fileLinks: WorkspaceFileLinks?
  // The liveness row's open sheet; a send can open Resume on a Machine.
  // swiftlint:disable:next private_swiftui_state
  @State var livenessSheets = SessionLivenessSheets()
  // One object for the chat's task markers, so the environment holding it stays the same.
  // swiftlint:disable:next private_swiftui_state
  @State var markerLinks = TaskMarkerLinks()

  /// The session's grants once read, for author badges.
  var loadedGrants: [OmnigentCoreFFI.SessionGrant] { shareStore?.grants.value ?? [] }

  var body: some View {
    let composer = conversation.composer
    let screen = state
    ConversationScreen(
      state: screen, composer: composerState(screen),
      draft: textSource.draft(conversation.composer, $textSource),
      showsInspector: showsInspector, inspectorTab: $inspectorTab,
      mode: modeRoute.mode(tabRoutes?.viewChoice, $modeRoute),
      fork: $forkFlow.sheet,
      actions: routed(forkable(actions)), composerActions: composerActions,
      extras: extras(sharing: shareStore),
      liveRows: ConversationAdapter.liveRows(conversation)
    ) {
      harnessTerminal
    }
    .modifier(MessageMediaEnvironment(fileLinks: fileLinks, conversation: conversation))
    .environment(\.taskMarkerLinks, taskMarkerLinks)
    .task(id: conversation.sessionID) { await tasks?.load() }
    .modifier(
      TasksTabOnOpen(
        sessionID: conversation.sessionID,
        known: TasksAdapter.tasksKnown(tasks, conversation: conversation),
        hasTasks: { TasksAdapter.hasTasks(tasks, conversation: conversation) }, show: showTasks)
    )
    .task(id: (linkedWorkspace ?? workspace).map(ObjectIdentifier.init)) {
      fileLinks = (linkedWorkspace ?? workspace).map { workspace in
        MarkdownLinksAdapter.links(workspace) { failures.append($0) }
      }
    }
    .fileExporter(
      isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
      document: export, contentType: TranscriptExport.contentType,
      defaultFilename: "\(conversation.sessionID).jsonl",
      onCompletion: exportFinished
    )
    .alert(
      "Something Went Wrong", isPresented: .constant(!failures.isEmpty),
      actions: { Button("OK") { failures = [] } },
      message: { Text(failures.joined(separator: "\n")) }
    )
    .task {
      if shareStore == nil { shareStore = makeShareStore?() }
      // As the web, an owner's grants say whether others write here, for author badges.
      if offersShare, let shareStore, ConversationAdapter.ownedByViewer(summary, server: server) {
        await shareStore.load()
      }
      composer.searchMentions = workspace.map(Self.mentionSearch)
      // A queued `/side` asks for its fork's tab when it goes out after the turn.
      SessionToolsAdapter.watchForks(conversation, routes: toolRoutes)
      await composer.loadConfiguration()
      if let agentID = composer.configuration?.agentId {
        await conversation.loadAgentInfo(agentID: agentID)
      }
      await composer.loadSkills()
    }
    // Reads the features too; the composer tray links the session's pull requests.
    .task { if !windowLoadsPanel { await panel?.reloadPullRequests() } }
    // The composer's chip keeps its PRs' checks and merge state current.
    .whileVisible(composerWatch)
    .modifier(
      SessionGoalPresenter(
        conversation: conversation, summary: summary, isPresented: $showsGoal,
        report: { failures.append($0) })
    )
    .modifier(
      SessionRewindPresenter(
        composer: composer, open: toolRoutes.openSession, report: { failures.append($0) })
    )
    .onChange(of: conversation.isRunning) { _, running in
      Task { await composer.drainQueue(isRunning: running) }
      if !running, !windowLoadsPanel { Task { await panel?.refreshPullRequestsIfShown() } }
    }
    .onChange(of: terminals?.terminals.harness, initial: true) { attachHarness() }
    .modifier(WorkspacePanelDefaults(workspace: ownPanelWorkspace, choice: $panelRoute.choice))
    .modifier(ComposerPreferencesReader(preferences: $composerPreferences))
    #if DEBUG
      .modifier(
        PerfConversationHooks(
          showPanel: PerfConversationHooks.showingPanel(
            window: tabRoutes?.windowPanel?.chrome, ownPanel: showsInspector,
            ownTab: $inspectorTab),
          openBrowser: tabRoutes?.openBrowser, openSideChat: tabRoutes?.openNewSideChat))
    #endif
    .modifier(ChangedFilesFollower(revision: changedFilesRevision, workspace: ownPanelWorkspace))
  }

  /// Keeps the composer chip's PRs current while the chat shows.
  private var composerWatch: (@MainActor (Bool) async -> Void)? {
    guard let panel else { return nil }
    return { resumed in await panel.watch(.composer, resumed: resumed) }
  }

  /// The workspace this chat's own right panel shows; none where the window shows the
  /// session's panel and follows its files itself.
  private var ownPanelWorkspace: WorkspaceBrowserModel? {
    tabRoutes?.windowPanel == nil ? workspace : nil
  }

  /// The chat's own panel: whether it shows, by the chat's choice or else the default where
  /// it is a column. The window's panel is not this one.
  private var showsInspector: Binding<Bool> {
    #if os(iOS)
      let isSheet = sizeClass == .compact
    #else
      let isSheet = false
    #endif
    return panelRoute.isShown(default: panelDefault, isSheet: isSheet, $panelRoute)
  }

  private func composerState(_ screen: ConversationViewState) -> ComposerViewState {
    var composer = ComposerAdapter.state(
      conversation, isStopping: isStopping, dismissedError: dismissedSendError, server: server,
      submitWithCommandReturn: composerPreferences.submitWithCommandReturn,
      windowShowsOutage: connectionHealth.map(ConnectionIssuesBanner.showsOutage) ?? false)
    composer.prefersSteer = composerPreferences.alwaysSteer
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
  var toolRoutes: SessionToolsAdapter.Routes {
    let showPullRequests: @MainActor () -> Void = {
      if let panel = tabRoutes?.windowPanel {
        panel.show(.pullRequests)
      } else {
        inspectorTab = .pullRequests
        panelRoute.choice = .open
      }
    }
    return SessionToolsAdapter.Routes(
      openSession: tabRoutes?.openSession ?? openSession,
      openNewSideChat: tabRoutes?.openNewSideChat,
      awaitForkedSideChat: tabRoutes?.awaitForkedSideChat,
      showPullRequests: showPullRequests,
      showGoal: {
        showsGoal = true
        Task { await conversation.tools.loadGoal() }
      },
      report: { failures.append($0) },
      showPullRequest: { [panel] url in
        showPullRequests()
        Task { await panel?.showPullRequest(url) }
      })
  }

  /// Shows the right panel on the Tasks tab: the window's, or this chat's own.
  func showTasks() {
    if let panel = tabRoutes?.windowPanel {
      panel.show(.tasks)
    } else {
      inspectorTab = .tasks
      panelRoute.choice = .open
    }
  }

  /// Side questions and sub-agents open in tabs beside this chat; the "Back to the parent
  /// session" capsule shows the parent's chat.
  func routed(_ actions: ConversationActions) -> ConversationActions {
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

  func beginFork(_ context: ForkContext) {
    guard let makeForkStore else { return }
    Task { await forkFlow.begin(context, makeStore: makeForkStore) }
  }
}

extension ConversationContainer {
  var actions: ConversationActions {
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
      validateForm: { card, values in
        .fromCore(cards: conversation.decisions.cards, cardID: card.id, values: values)
      },
      dismissError: { conversation.dismissErrors() },
      retry: retry,
      resume: { Task { await conversation.recoverTurn(.resume) } })
    actions.loadOlder = { conversation.loadOlderHistory() }
    actions.openSignIn = openSignIn
    actions.sessionTitle = sessionTitle
    // Edit and resend, wherever the viewer could type the message.
    if !ComposerAdapter.isReadOnly(conversation) {
      let composer = conversation.composer
      actions.editSentMessage = { row in composer.editSentMessage(row.text) }
      actions.viewerID = server?.userId
    }
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

  var composerActions: ComposerActions {
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
        // Dismissing also drops a message the banner offered to restore.
        composer.discardUnsent()
      },
      extras: extras)
  }

  /// Sends the composer's draft.
  func sendDraft() {
    dismissedSendError = nil
    let (conversation, newSession, routes) = (conversation, sessionActions.newSession, toolRoutes)
    Task {
      await SessionToolsAdapter.send(conversation, newSession: newSession, routes: routes)
    }
  }
}
