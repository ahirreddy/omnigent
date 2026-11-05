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
/// The detail shows the window's tabs (``TabStore``): selecting a session in the sidebar opens
/// or focuses its chat tab, and terminals, side chats and browser pages open as tabs too. A
/// session's conversation, terminals and workspace stay open while a built tab shows it; the core
/// is told which session is visible for notifications and the badge.
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
  @AppStorage(InterfacePreferences.openLinksInAppKey) private var openLinksInApp = false
  @AppStorage(InterfacePreferences.openSubagentsInPanelKey) private var openSubagentsBeside = false

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
    AppShell(
      sidebar: sidebarState, selection: $selection, searchText: searchBinding,
      actions: sidebarActions, tabs: (tabs.state, renamable(tabs.actions))
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
    .modifier(TabRestoration(session: session, context: tabContext) { route(selection) })
    .modifier(SessionTabsLifecycle(session: session))
    .modifier(CloseShellConfirmation(session: session) { tabFailure = $0 })
    .onChange(of: selection) { _, current in route(current) }
    .onChange(of: session.tabs.selectedID, initial: true) { selectedTabChanged() }
    // A background tab whose work settles gets the unread dot until it is shown.
    .onChange(of: tabs.state.busyIDs, initial: true) { _, busy in session.tabs.noteBusy(busy) }
    .onChange(of: isWindowFocused) { report() }
    .task(id: connection.connectedServer?.baseUrl) {
      if connection.connectedServer != nil { await connection.loadOfferedPages() }
    }
    .sheet(isPresented: $showsTabOverview) {
      TabOverviewSheet(state: tabs.state, actions: tabs.actions) { showsTabOverview = false }
    }
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
      guard let id = tabs.tab(tabID)?.content.sessionID, let summary = list.session(id) else {
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
          opener: windowTabs.linkOpener(opener, inApp: openLinksInApp),
          openSession: { selection = .session($0) },
          retry: { connection.foreground() },
          server: connection.connectedServer,
          tabRoutes: windowTabs.routes(for: id, subagentsBeside: openSubagentsBeside),
          terminalNames: session.declaredTerminalNames(in: id),
          sessionActions: sidebarActions.sessions,
          makeForkStore: { connection.makeForkStore() },
          menuContext: ConversationContainer.menuContext(
            connection.sessionList, session: connection.sessionList.session(id),
            sideChatOf: source),
          makeShareStore: { connection.share(sessionID: id) },
          offersShare: source == nil && connection.pages?.offered?.sharing == true
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
      fail: { tabFailure = $0 }, supportsSplit: sizeClass != .compact)
  }

  private var tabFailurePresented: Binding<Bool> {
    Binding(get: { tabFailure != nil }, set: { if !$0 { tabFailure = nil } })
  }

  /// The session whose chat is on screen, for notification suppression.
  var viewedSessionID: String? {
    if case .chat(let id) = session.tabs.selected?.content { return id }
    return nil
  }

  /// The selected tab's content, or each pane's in a split window, and the new-tab page when no
  /// tab is open. Without a split, recently shown chats stay built underneath (``KeptAliveTabs``)
  /// so switching back to one is immediate.
  @ViewBuilder private var tabDetail: some View {
    let tabs = session.tabs
    let routes = windowTabs
    if let selected = tabs.selected {
      TabSplitView(split: tabs.splitState, actions: routes.actions) { pane in
        if tabs.split == nil, sizeClass != .compact {
          KeptAliveTabs(tabs.keptAlive(), shownID: selected.id) { tab in
            tabContent(tab, routes: routes)
          }
        } else if let tab = paneTab(pane) {
          tabContent(tab, routes: routes)
        }
      }
    } else {
      NewTabPage(state: routes.newTabState, actions: routes.newTabActions(replacing: nil))
    }
  }

  /// The tab a pane shows: the selected tab when the window is not split.
  private func paneTab(_ pane: TabPane) -> AppTab? {
    let tabs = session.tabs
    guard let split = tabs.splitState else { return tabs.selected }
    return split.activeID(pane).flatMap(tabs.tab)
  }

  /// A tab's content: the sidebar destinations through ``detail(_:)``, the other kinds through
  /// their tab views.
  private func tabContent(_ tab: AppTab, routes: WindowTabs) -> some View {
    let tabs = session.tabs
    return Group {
      switch tab.content {
      case .chat, .newSession, .inbox, .canvas, .automations, .usage:
        detail(tab.content.destination)
      case .newTab:
        NewTabPage(state: routes.newTabState, actions: routes.newTabActions(replacing: tab.id))
          .task(id: routes.newTabState.recentSessions.map(\.id)) {
            let recent = routes.newTabState.recentSessions.map(\.id)
            async let profiles: Void = session.loadRemoteBrowserProfiles(recent.first)
            await session.loadDeclaredTerminalNames(recent)
            await profiles
          }
      case .terminal(let sessionID, let terminalID):
        TerminalTabView(
          session: session, sessionID: sessionID, terminalID: terminalID,
          showChat: { tabs.open(.chat(sessionID: sessionID)) })
      case .harness(let sessionID):
        HarnessTabView(
          session: session, sessionID: sessionID,
          showChat: { tabs.open(.chat(sessionID: sessionID)) })
      case .sideChat(let sessionID, let rowID):
        SideChatTabContainer(
          session: session, sessionID: sessionID, rowID: rowID,
          showChat: { tabs.open(.chat(sessionID: sessionID)) })
      case .sideChatSession(let parentID, let childID):
        sideChat(tab, parentID: parentID, childID: childID, routes: routes)
      case .browser(let browserID):
        BrowserTabContainer(
          host: tabContext.browser, tab: tab, browserID: browserID,
          changed: { tabs.contentChanged() })
      case .agentBrowser(let sessionID):
        AgentBrowserTabContainer(
          host: tabContext.browser, sessionID: sessionID,
          showChat: { tabs.open(.chat(sessionID: sessionID)) })
      case .remoteBrowser(let sessionID, let tabID):
        RemoteBrowserTabContainer(
          session: session, tab: tab, sessionID: sessionID, tabID: tabID,
          reopen: { url, record in
            Task {
              await routes.openRemoteBrowser(
                in: sessionID, profile: record.profile, url: url, replacing: tab.id)
            }
          },
          // On iPhone the remote tab hides the navigation bar (Safari's layout), so it offers
          // the session list and the tab overview itself.
          showSessions: { selection = nil },
          tabsButton: { TabSwitcherButton(state: routes.state, actions: routes.actions) })
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

  /// The sidebar row for a tab. Session terminals and side chats select their session only at
  /// compact widths, where the selection is what keeps the detail on screen.
  private func sidebarDestination(_ tab: AppTab?) -> SidebarDestination? {
    guard let tab else { return nil }
    if let destination = tab.content.destination { return destination }
    guard sizeClass == .compact else { return nil }
    return tab.content.sessionID.map(SidebarDestination.session) ?? .newSession
  }

  /// A sidebar choice (or a deep link) opens or focuses its tab.
  private func route(_ destination: SidebarDestination?) {
    guard let destination, destination != sidebarDestination(session.tabs.selected) else {
      return
    }
    session.tabs.open(AppTabContent(destination))
  }

  private func selectedTabChanged() {
    let mapped = sidebarDestination(session.tabs.selected)
    if selection != mapped { selection = mapped }
    report()
  }

  /// A session the new-session form created replaces the form's tab.
  private func showCreated(_ sessionID: String) {
    let tabs = session.tabs
    if let selected = tabs.selected, selected.content == .newSession {
      tabs.replace(selected.id, with: .chat(sessionID: sessionID))
    } else {
      tabs.open(.chat(sessionID: sessionID))
    }
  }

  /// Previous and Next Session show the session in the current tab when it may be replaced; a
  /// primary chat never is, so the session's own chat opens or is focused.
  func showInPlace(_ sessionID: String) {
    session.tabs.navigate(to: .chat(sessionID: sessionID)) { content in
      if case .chat = content { return true }
      return false
    }
  }
}
