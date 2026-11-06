import Foundation
import OmnigentAuthUI
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
  @Binding private var selection: SidebarDestination?
  let isWindowFocused: Bool
  private let opener: ExternalURLOpener
  let openInNewWindow: (@MainActor (String) -> Void)?
  private let tabContext: TabWindowContext
  let serverSwitching: ServerSwitching?

  @State private var sidebar = SidebarModel()
  @State private var sidebarMemo = SidebarStateMemo()
  @State private var showsTabOverview = false
  @State private var tabFailure: String?
  @State private var tabCommandRelay = FocusedActionsRelay<TabCommandActions>()
  /// The session a chat tab's Rename Session is renaming.
  @State private var renamingFromTab: OmnigentUIComponents.SessionSummary?
  @State private var renameText = ""
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

  var connection: ConnectionStore { session.connection }
  /// The sidebar's display options, undo and fork sheet.
  var sidebarModel: SidebarModel { sidebar }
  /// What the detail shows.
  var selectionBinding: Binding<SidebarDestination?> { $selection }

  /// The connected server’s sidebar and selected destination.
  public var body: some View {
    let tabs = windowTabs
    let strip = tabs.strip
    AppShell(
      sidebar: sidebarState, selection: pageBinding, searchText: searchBinding,
      actions: sidebarActions, tabs: strip.map { ($0.state, renamable($0.actions)) }
    ) { _ in
      tabDetail
        .safeAreaInset(edge: .top, spacing: 0) {
          ConnectionIssuesBanner(connection: connection)
        }
    }
    .environment(\.tabStatusDetails, TabAdapter.statusDetails(session))
    .modifier(PaletteAdapter(session: session, selection: $selection))
    .background { PinnedSessionShortcuts(open: openPinnedSession) }
    .copyConfirmations()
    .environment(\.transcriptFocus, session.transcriptFocus)
    .toolbar { accountToolbar }
    .focusedSceneValue(\.tabCommands, tabCommandRelay.publish(tabs.commands))
    .modifier(TabRestoration(session: session, context: tabContext) { restore($0) })
    .modifier(SessionTabsLifecycle(session: session))
    .modifier(CloseShellConfirmation(session: session) { tabFailure = $0 })
    .onChange(of: selection) { _, current in session.tabs.show(current) }
    .onChange(of: session.tabs.page) { _, page in pageChanged(page) }
    .onChange(of: viewedSessionID) { report() }
    // A background tab whose work settles gets the unread dot until it is shown.
    .onChange(of: strip?.state.busyIDs ?? [], initial: true) { _, busy in
      session.tabs.current?.noteBusy(busy)
    }
    .onChange(of: isWindowFocused) { report() }
    .task(id: connection.connectedServer?.baseUrl) {
      if connection.connectedServer != nil { await connection.loadOfferedPages() }
    }
    .tabOverview(
      isPresented: $showsTabOverview, state: strip?.state ?? TabsState(),
      actions: strip?.actions ?? TabActions()
    )
    .alert("Could Not Open the Tab", isPresented: tabFailurePresented) {
      Button("OK") { tabFailure = nil }
    } message: {
      Text(tabFailure ?? "")
    }
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
    .sessionRenamePrompt($renamingFromTab, text: $renameText) { summary, title in
      rename(summary.id, to: title)
    }
  }

  /// A chat tab's menu renames its session, as the session menu and Option-Command-R do.
  private func renamable(_ actions: TabActions) -> TabActions {
    var actions = actions
    let tabs = session.tabs
    let list = connection.sessionList
    actions.renameSession = { tabID in
      guard let id = tabs.tab(tabID)?.sessionID, let summary = list.session(id) else {
        return
      }
      renameText = summary.title
      renamingFromTab = OmnigentUIComponents.SessionSummary(summary)
    }
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

  @ToolbarContentBuilder private var accountToolbar: some ToolbarContent {
    if case .connected(let account) = session.signIn.state.phase, account.canSignOut {
      ToolbarItem(placement: .automatic) {
        AccountChip(account: account, actions: session.signIn.actions)
      }
    }
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
      if let conversation = connection.conversations[id] {
        ConversationContainer(
          conversation: conversation, summary: connection.sessionList.session(id),
          terminals: session.terminalStores[id], workspace: session.workspaces[id],
          panel: session.panels[id],
          changedFilesRevision: connection.changedFilesRevision,
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
            connection.sessionList, session: connection.sessionList.session(id),
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

  private var tabFailurePresented: Binding<Bool> {
    Binding(get: { tabFailure != nil }, set: { if !$0 { tabFailure = nil } })
  }

  /// The sidebar's selection: the window's page. A choice shows its page at once, before the
  /// host's selection reaches `onChange`.
  private var pageBinding: Binding<SidebarDestination?> {
    let tabs = session.tabs
    let selection = selectionBinding
    return Binding(
      get: { selection.wrappedValue },
      set: { page in
        selection.wrappedValue = page
        tabs.show(page)
      })
  }

  /// The session whose chat is on screen, for notification suppression.
  var viewedSessionID: String? {
    guard let tabs = session.tabs.current else { return nil }
    let visible = tabs.visibleIDs.compactMap(tabs.tab)
    return visible.lazy.compactMap { tab -> String? in
      if case .chat(let id) = tab.content { return id }
      return nil
    }.first
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
    ZStack {
      TabSplitView(
        split: store?.splitState, actions: store.map(routes.actions) ?? TabActions()
      ) { pane in
        if keepsAlive {
          KeptAliveTabs(
            keptAlive(page: page, isCompact: sizeClass == .compact),
            shownID: store?.selectedID ?? page?.id ?? ""
          ) { tab in
            tabContent(tab, routes: routes)
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
      case .harness(let sessionID):
        HarnessTabView(
          session: session, sessionID: sessionID, showChat: { tabs.showChat(sessionID) })
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

  /// Previous and Next Session, and the pinned-session shortcuts, show the session's tabs.
  func showInPlace(_ sessionID: String) {
    selection = .session(sessionID)
  }
}
