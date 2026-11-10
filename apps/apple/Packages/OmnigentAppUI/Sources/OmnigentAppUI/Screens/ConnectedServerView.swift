import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
public import OmnigentUIComponents
public import SwiftUI

/// The signed-in app for one server: the web's two-column shell (`AppShell`: sidebar and detail,
/// with the session's right panel as the detail's inspector), collapsing to a stack on iPhone.
///
/// Tabs are scoped per session (``SessionTabGroups``): selecting a session in the sidebar shows its
/// tabs (primary chat, side chats, terminals, browser pages) in the strip, as it left them, and a
/// session-less page (New Session, Inbox, Canvas, Automations, Usage) at full size without a
/// strip. The recently shown sessions' conversations, terminals and workspaces stay open; the
/// core is told which session's chat is visible for notifications and the badge.
public struct ConnectedServerView: View {
  let session: ServerSession
  /// What the detail shows. The window's body never reads it: a body that does runs again each
  /// time a session or a page is chosen.
  @Binding private var selection: SidebarDestination?
  let isWindowFocused: Bool
  private let opener: ExternalURLOpener
  let openInNewWindow: (@MainActor (String) -> Void)?
  private let tabContext: TabWindowContext
  let serverSwitching: ServerSwitching?

  @State private var sidebar = SidebarModel()
  @State private var sidebarMemo = SidebarStateMemo()
  /// UI tests and screenshots pass `-OmnigentShowTabOverview` to open it at launch.
  @State private var showsTabOverview = ProcessInfo.processInfo.arguments.contains(
    "-OmnigentShowTabOverview")
  @State private var overviewPresenter = TabOverviewPresenter()
  @State private var tabFailure: String?
  @State private var tabCommandRelay = FocusedActionsRelay<TabCommandActions>()
  /// The session a chat tab's Rename Session is renaming.
  @Environment(\.horizontalSizeClass) private var sizeClass
  @Environment(\.openSettingsAt) private var openSettingsAt
  @AppStorage(InterfacePreferences.openLinksInAppKey) private var openLinksInApp = false
  @AppStorage(InterfacePreferences.openSubagentsInPanelKey) private var openSubagentsApart = false

  /// Creates the view.
  /// - Parameters:
  ///   - session: The signed-in connection.
  ///   - selection: What the detail shows; the host keeps it so deep links can set it.
  ///   - isWindowFocused: Whether the window is key, for notification suppression.
  ///   - opener: Opens pages in the system browser.
  ///   - openInNewWindow: Opens a session in a new window, where the platform has windows.
  ///   - tabContext: Where the window's tabs are saved, the browser, and tear-off.
  ///   - serverSwitching: Other servers the sidebar's switcher offers, where windows can switch.
  public init(
    session: ServerSession, selection: Binding<SidebarDestination?>,
    isWindowFocused: Bool = true, opener: ExternalURLOpener = .system,
    openInNewWindow: (@MainActor (String) -> Void)? = nil,
    tabContext: TabWindowContext = TabWindowContext(),
    serverSwitching: ServerSwitching? = nil
  ) {
    self.session = session
    _selection = selection
    self.isWindowFocused = isWindowFocused
    self.opener = opener
    self.openInNewWindow = openInNewWindow
    self.tabContext = tabContext
    self.serverSwitching = serverSwitching
  }

  /// A view whose sidebar state the caller holds.
  init(
    session: ServerSession, selection: Binding<SidebarDestination?>, sidebar: SidebarModel,
    opener: ExternalURLOpener, openInNewWindow: (@MainActor (String) -> Void)?,
    serverSwitching: ServerSwitching?
  ) {
    self.init(
      session: session, selection: selection, opener: opener, openInNewWindow: openInNewWindow,
      serverSwitching: serverSwitching)
    _sidebar = State(initialValue: sidebar)
  }

  var connection: ConnectionStore { session.connection }
  /// The sidebar's display options, undo and fork sheet.
  var sidebarModel: SidebarModel { sidebar }
  /// What the detail shows.
  var selectionBinding: Binding<SidebarDestination?> { $selection }

  /// The connected server’s sidebar and selected destination.
  public var body: some View {
    let tabs = windowTabs
    // The sidebar, the strip and the detail read their state where they show it: a session's
    // row, a tab's title, the shown tab or the selection that changes then renders that part,
    // not the window.
    AppShell(
      sidebar: { sidebarState }, selection: selectionBinding, searchText: { searchBinding },
      actions: sidebarActions, tabs: strip(of: tabs),
      detail: {
        ObservationScope("detail") {
          tabDetail
            .safeAreaInset(edge: .top, spacing: 0) {
              VStack(spacing: 0) {
                ConnectionIssuesBanner(connection: connection)
                if let tabFailure {
                  TabFailureBanner(message: tabFailure) { self.tabFailure = nil }
                }
              }
            }
        }
      }
    )
    .countsRenders("window")
    .environment(\.tabStatusDetails, TabAdapter.statusDetails(session))
    .environment(\.tabOverviewPresenter, overviewPresenter)
    .onAppear { overviewPresenter.open = { showsTabOverview = true } }
    .modifier(PaletteAdapter(session: session, selection: $selection))
    .background { PinnedSessionShortcuts(open: openPinnedSession) }
    .copyConfirmations()
    .environment(\.transcriptFocus, session.transcriptFocus)
    .modifier(TabCommandsPublishing(tabs: tabs, relay: tabCommandRelay))
    .modifier(TabRestoration(session: session, context: tabContext) { restore($0) })
    .modifier(SessionTabsLifecycle(session: session))
    .modifier(NewTabOptionsLoading(session: session))
    .modifier(CloseShellConfirmation(session: session) { tabFailure = $0 })
    .modifier(SelectedPageShown(selection: selectionBinding, tabs: session.tabs))
    .modifier(ShownPageReport(tabs: session.tabs) { pageChanged($0) })
    .modifier(viewedSessionReport)
    .modifier(BusyTabsReport(tabs: tabs))
    .task(id: connection.connectedServer?.baseUrl) {
      if connection.connectedServer != nil { await connection.loadOfferedPages() }
    }
    .modifier(WindowTabOverview(tabs: tabs, isPresented: $showsTabOverview))
    .alert(
      "Could Not Update the Session", isPresented: editErrorPresented,
      actions: { Button("OK") { connection.sessionList.dismissEditError() } },
      message: { Text(connection.sessionList.editError?.message ?? "") }
    )
    .sheet(isPresented: sidebarForkPresented) {
      if let fork = sidebar.fork.viewState {
        ForkSheet(state: fork, actions: sidebarForkActions)
      }
    }
    .sheet(isPresented: sidebarSharePresented) { sidebarShareSheet }
    .sheet(item: $sidebar.projectSettings) { flow in projectSettingsSheet(flow) }
    .archiveWorktreePrompt($sidebar.archiveRequest) { request, delete, remember in
      archiveAnswered(request, delete: delete, remember: remember)
    }
    .sessionRenamePrompt($sidebar.renamingFromTab, text: $sidebar.renameText) { summary, title in
      rename(summary.id, to: title)
    }
  }

  /// The strip's tabs, read when the titlebar asks for them; a session-less page has no strip.
  /// They are the last shown session's, which a page leaves as they were: going to a page then
  /// takes the strip away without rendering it first.
  private func strip(of tabs: WindowTabs) -> ShellTabs {
    ShellTabs(
      isShown: { tabs.groups.currentSessionID != nil },
      content: {
        guard let store = tabs.groups.lastShown else { return (TabsState(), TabActions()) }
        return (tabs.state(store), renamable(tabs.actions(store)))
      })
  }

  /// A chat tab's menu renames its session, as the session menu and Option-Command-R do.
  private func renamable(_ actions: TabActions) -> TabActions {
    var actions = actions
    let (model, tabs, list) = (sidebarModel, session.tabs, connection.sessionList)
    actions.renameSession = { model.askToRename(tabID: $0, tabs: tabs, list: list) }
    return actions
  }

  var sidebarState: SidebarViewState {
    var state = sidebarMemo.state(
      list: connection.sessionList, display: sidebar.display,
      server: connection.connectedServer,
      servers: serverSwitching?.choices ?? [])
    state.undo = sidebar.undo?.banner
    state.showsAutomations = connection.pages?.offered?.automations == true
    state.showsUsage = connection.pages?.offered?.usage == true
    state.showsCanvas = connection.pages?.offered?.canvas == true
    state.showsSharedScope = connection.pages?.offered?.sharing ?? true
    state.projectSort = connection.sessionList.projectSortMode.map {
      $0 == .manual ? .manual : .alphabetical
    }
    state.account = signOutAccount
    return state
  }

  private var searchBinding: Binding<String> {
    let list = connection.sessionList
    return Binding(get: { list.searchText }, set: { list.searchText = $0 })
  }

  private var editErrorPresented: Binding<Bool> {
    let list = connection.sessionList
    return Binding(
      get: { list.editError != nil }, set: { if !$0 { list.dismissEditError() } })
  }

  /// Links from a session's chat: server links in the app, others in a browser tab or outside.
  private func linkOpener(in sessionID: String) -> ExternalURLOpener {
    serverLinkOpener(
      windowTabs.linkOpener(opener, inApp: openLinksInApp, in: sessionID),
      openSettings: openSettingsAt)
  }

  /// A destination's content; `sideChatOf` names the session a side chat was forked from.
  @ViewBuilder private func detail(
    _ destination: SidebarDestination?, sideChatOf source: String? = nil
  ) -> some View {
    switch destination {
    case .session(let id):
      if let conversation = connection.openConversation(id) {
        ConversationContainer(
          conversation: conversation, summary: connection.sessionList.sessionWithoutActivity(id),
          terminals: session.terminals(of: id), workspace: session.workspace(of: id),
          panel: session.panel(of: id),
          changedFilesRevision: { connection.changedFilesRevision },
          navigation: navigation(from: id),
          opener: linkOpener(in: id),
          openSession: { selection = .session($0) },
          retry: { connection.foreground() },
          server: connection.connectedServer,
          tabRoutes: windowTabs.routes(for: id, subagentsApart: openSubagentsApart),
          terminalNames: session.declaredTerminalNames(in: id),
          sessionActions: sidebarActions.sessions,
          makeForkStore: { connection.makeForkStore() },
          menuContext: ConversationContainer.menuContext(
            connection.sessionList, session: connection.sessionList.sessionWithoutActivity(id),
            sideChatOf: source),
          makeShareStore: { connection.share(sessionID: id) },
          offersShare: source == nil && ShareAdapter.offered(connection.pages?.offered),
          shareUnavailableReason: ShareAdapter.unavailableReason(connection.pages?.offered)
        )
        .id(id)
      } else {
        ProgressView("Opening the session\u{2026}")
      }
    case .newSession:
      NewSessionContainer(connection: connection) { showCreated($0) }
    case .inbox:
      InboxTriageAdapter(
        connection: connection, open: { selection = .session($0) },
        openFile: { session.openFile($0, at: $1, in: $2) })
    case .canvas:
      CanvasAdapter(
        connection: connection, open: { selection = .session($0) },
        newSession: { selection = .newSession })
    case .automations:
      AutomationsAdapter(connection: connection) { selection = .session($0) }
    case .usage:
      UsageAdapter(connection: connection) { selection = .session($0) }
    case nil:
      ContentUnavailableView {
        Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
      } description: {
        Text("Choose a session in the sidebar, or start a new one.")
      }
    }
  }

}

// MARK: Tabs

extension ConnectedServerView {
  var windowTabs: WindowTabs {
    WindowTabs(
      session: session, context: tabContext, showAll: { showsTabOverview = true },
      fail: { tabFailure = $0 }, supportsSplit: sizeClass != .compact,
      openInNewWindow: openInNewWindow)
  }

  /// Tells the core which session's chat is on screen, for notifications and the badge.
  private var viewedSessionReport: ViewedSessionReport {
    let connection = connection
    return ViewedSessionReport(tabs: session.tabs, isWindowFocused: isWindowFocused) {
      connection.setView(sessionID: $0, focused: $1)
    }
  }

  /// The shown session's tabs, or a session-less page over them. The tabs stay mounted under a
  /// page, so recently shown chats (``KeptAliveTabs``) are still built when a session comes back.
  @ViewBuilder private var tabDetail: some View {
    let tabs = session.tabs
    let routes = windowTabs
    let store = tabs.current
    let keepsAlive = store?.split == nil
    // A session-less page shows among the kept-alive tabs, which stay built underneath it.
    let page = store == nil && keepsAlive ? tabs.page.map(Self.pageTab) : nil
    // Read here, not in the pane's content: the split view would follow the selection as well,
    // and render the shown tab a second time for each switch.
    let kept = keepsAlive ? keptAlive(page: page, isCompact: sizeClass == .compact) : []
    let shownID = store?.selectedID ?? page?.id ?? ""
    ZStack {
      TabSplitView(
        split: store?.splitState, actions: store.map(routes.actions) ?? TabActions()
      ) { pane in
        if keepsAlive {
          // Each tab reads its own session, so one session's change leaves the other tabs alone.
          KeptAliveTabs(kept, shownID: shownID) { tab in
            ObservationScope("tab") { tabContent(tab, routes: routes) }
          }
        } else if let store, let tab = paneTab(pane, in: store) {
          tabContent(tab, routes: routes)
        }
      }
      if store == nil, page == nil {
        detail(tabs.page)
          .zIndex(1)
      }
    }
  }

  /// A tab's content: a session's chat through ``detail(_:)``, the other kinds through their
  /// tab views.
  private func tabContent(_ tab: AppTab, routes: WindowTabs) -> some View {
    let tabs = session.tabs
    return Group {
      switch tab.content {
      case .chat, .newSession, .inbox, .canvas, .automations, .usage:
        detail(tab.content.destination)
      case .newTab:
        newTabPage(tab, routes: routes)
      case .terminal(let sessionID, let terminalID):
        TerminalTabView(
          session: session, sessionID: sessionID, terminalID: terminalID,
          showChat: { tabs.showChat(sessionID) })
      // The agent's terminal shows in its session's chat; a tab left for it shows that chat.
      case .harness(let sessionID):
        detail(.session(sessionID))
      case .sideChat(let sessionID, let rowID):
        SideChatTabContainer(
          session: session, sessionID: sessionID, rowID: rowID,
          showChat: { tabs.showChat(sessionID) })
      case .sideChatSession(let parentID, let childID):
        sideChat(tab, parentID: parentID, childID: childID, routes: routes)
      case .browser(let browserID):
        BrowserTabContainer(
          host: tabContext.browser, tab: tab, browserID: browserID,
          // On iPhone the page hides the navigation bar and shows these beside its address.
          navigation: BrowserTabNavigation(
            showSessions: { selection = nil }, tabsButton: AnyView(tabsButton(routes))),
          changed: { tabs.tab(tab.id).flatMap { tabs.groups[$0.sessionID] }?.contentChanged() })
      case .agentBrowser(let sessionID):
        AgentBrowserTabContainer(
          host: tabContext.browser, sessionID: sessionID, showChat: { tabs.showChat(sessionID) })
      case .remoteBrowser(let sessionID, let tabID):
        remoteBrowser(tab, sessionID: sessionID, tabID: tabID, routes: routes)
      }
    }
    .id(tab.id)
  }

  /// A side chat's tab: its session once its first message created it, else the unsent one.
  @ViewBuilder private func sideChat(
    _ tab: AppTab, parentID: String, childID: String?, routes: WindowTabs
  ) -> some View {
    if let childID {
      detail(.session(childID), sideChatOf: parentID)
    } else {
      PendingSideChatTab(session: session, tabID: tab.id, parentID: parentID, fail: routes.fail)
    }
  }

  /// The window's saved page applies unless the host already chose one (a deep link, a new
  /// window for a session).
  private func restore(_ saved: SidebarDestination?) {
    if selection == nil, let saved { selection = saved }
    session.tabs.show(selection)
  }

  /// The page changed from the model (a removed session, a tab opened in another session).
  private func pageChanged(_ page: SidebarDestination?) {
    if selection != page { selection = page }
    report()
  }

  /// A session the new-session form created shows in place of the form.
  private func showCreated(_ sessionID: String) {
    selection = .session(sessionID)
  }
}
