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
  private let session: ServerSession
  @Binding private var selection: SidebarDestination?
  private let isWindowFocused: Bool
  private let opener: ExternalURLOpener
  private let openInNewWindow: (@MainActor (String) -> Void)?
  private let tabContext: TabWindowContext

  @State private var display = SessionDisplayOptions()
  @State private var undo: SidebarUndo?
  @State private var showsTabOverview = false
  @State private var tabFailure: String?
  @State private var tabCommandRelay = FocusedActionsRelay<TabCommandActions>()
  @Environment(\.horizontalSizeClass) private var sizeClass

  /// Creates the view.
  /// - Parameters:
  ///   - session: The signed-in connection.
  ///   - selection: What the detail shows; the host keeps it so deep links can set it.
  ///   - isWindowFocused: Whether the window is key, for notification suppression.
  ///   - opener: Opens pages in the system browser.
  ///   - openInNewWindow: Opens a session in a new window, where the platform has windows.
  ///   - tabContext: Where the window's tabs are saved, the browser, and tear-off.
  public init(
    session: ServerSession, selection: Binding<SidebarDestination?>,
    isWindowFocused: Bool = true, opener: ExternalURLOpener = .system,
    openInNewWindow: (@MainActor (String) -> Void)? = nil,
    tabContext: TabWindowContext = TabWindowContext()
  ) {
    self.session = session
    _selection = selection
    self.isWindowFocused = isWindowFocused
    self.opener = opener
    self.openInNewWindow = openInNewWindow
    self.tabContext = tabContext
  }

  private var connection: ConnectionStore { session.connection }

  /// The connected server’s sidebar and selected destination.
  public var body: some View {
    let tabs = windowTabs
    AppShell(
      sidebar: sidebarState, selection: $selection, searchText: searchBinding,
      actions: sidebarActions, tabs: (tabs.state, tabs.actions)
    ) { _ in
      tabDetail
        .safeAreaInset(edge: .top, spacing: 0) {
          ConnectionIssuesBanner(connection: connection)
        }
    }
    .modifier(PaletteAdapter(session: session, selection: $selection))
    .toolbar { accountToolbar }
    .focusedSceneValue(\.tabCommands, tabCommandRelay.publish(tabs.commands))
    .modifier(TabRestoration(session: session, context: tabContext) { route(selection) })
    .modifier(SessionTabsLifecycle(session: session))
    .onChange(of: selection) { _, current in route(current) }
    .onChange(of: session.tabs.selectedID, initial: true) { selectedTabChanged() }
    // A background tab whose work settles gets the unread dot until it is shown.
    .onChange(of: tabs.state.busyIDs, initial: true) { _, busy in session.tabs.noteBusy(busy) }
    .onChange(of: isWindowFocused) { report() }
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
      message: { Text(connection.sessionList.editError?.message ?? "") })
  }

  private var sidebarState: SidebarViewState {
    var state = SidebarAdapter.state(
      list: connection.sessionList, display: display, server: connection.connectedServer)
    state.undo = undo?.banner
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

  @ViewBuilder private func detail(_ destination: SidebarDestination?) -> some View {
    switch destination {
    case .session(let id):
      if let conversation = connection.conversations[id] {
        ConversationContainer(
          conversation: conversation, summary: connection.sessionList.session(id),
          terminals: session.terminalStores[id], workspace: session.workspaces[id],
          changedFilesRevision: connection.changedFilesRevision,
          navigation: navigation(from: id), opener: opener,
          openSession: { selection = .session($0) },
          retry: { connection.foreground() },
          server: connection.connectedServer,
          tabRoutes: windowTabs.routes(for: id),
          terminalNames: session.declaredTerminalNames(in: id),
          sessionActions: sidebarActions.sessions,
          makeForkStore: { connection.makeForkStore() }
        )
        .id(id)
      } else {
        ProgressView("Opening the session\u{2026}")
      }
    case .newSession:
      NewSessionContainer(connection: connection) { showCreated($0) }
    case .inbox:
      InboxTriageAdapter(connection: connection) { selection = .session($0) }
    case .canvas:
      CanvasView(
        sessions: connection.sessionList.visible.map(OmnigentUIComponents.SessionSummary.init),
        open: { selection = .session($0) })
    case nil:
      ContentUnavailableView {
        Label("No Session Selected", systemImage: "bubble.left.and.text.bubble.right")
      } description: {
        Text("Choose a session in the sidebar, or start a new one.")
      }
    }
  }

  private var sidebarActions: SidebarActions {
    let list = connection.sessionList
    let connection = connection
    let server = connection.connectedServer
    var openInWindow: (@MainActor (OmnigentUIComponents.SessionSummary) -> Void)?
    if let open = openInNewWindow {
      openInWindow = { summary in open(summary.id) }
    }
    return SidebarActions(
      sessions: SessionListActions(
        setFilter: { list.filter = OmnigentCoreFFI.SessionFilter($0) },
        setPinned: { summary, pinned in edit(.pin(summary.id, pinned)) },
        setArchived: { summary, archived in edit(.archive([summary.id], archived)) },
        rename: { summary, title in rename(summary.id, to: title) },
        openInNewWindow: openInWindow,
        webURL: { SidebarAdapter.webURL(server: server, sessionID: $0.id) },
        newSession: { selection = .newSession },
        retry: { connection.refreshSessions() }),
      setDisplay: { display = $0 },
      setQuickFilter: { list.filter = OmnigentCoreFFI.SessionFilter($0 ?? .all) },
      undo: { _ in
        guard let undo else { return }
        self.undo = nil
        edit(undo.inverse, recordUndo: false)
      },
      dismissUndo: { undo = nil },
      viewArchived: { list.filter = .archived })
  }

  /// Renames through the session list, which reports a failure in `editError` (shown above).
  private func rename(_ sessionID: String, to title: String) {
    let list = connection.sessionList
    Task {
      // The Boolean only repeats whether `editError` was set.
      _ = await list.rename(sessionID, to: title)
    }
  }

  /// Pins or archives through the session list (which reports failures in `editError`), and
  /// offers Undo for the change.
  private func edit(_ change: SidebarUndo.Change, recordUndo: Bool = true) {
    let list = connection.sessionList
    Task {
      var succeeded = true
      switch change {
      case .pin(let id, let pinned):
        succeeded = await list.setPinned(id, pinned)
      case .archive(let ids, let archived):
        for id in ids where succeeded {
          succeeded = await list.setArchived(id, archived)
        }
        if archived {
          // An archived session's tabs leave with it, its primary chat among them.
          session.tabs.removeSessions(Set(ids))
        }
      }
      if succeeded, recordUndo { undo = SidebarUndo(change: change) }
    }
  }

  /// Previous and next session in the sidebar's order.
  private func navigation(from id: String) -> SessionCommandActions {
    let ids = connection.sessionList.visible.map(\.id)
    guard let index = ids.firstIndex(of: id) else { return SessionCommandActions() }
    let previous = index > ids.startIndex ? ids[index - 1] : nil
    let next = index + 1 < ids.endIndex ? ids[index + 1] : nil
    var actions = SessionCommandActions()
    if let previous {
      actions.previousSession = { showInPlace(previous) }
    }
    if let next {
      actions.nextSession = { showInPlace(next) }
    }
    return actions
  }

  private func report() {
    connection.setView(sessionID: viewedSessionID, focused: isWindowFocused)
  }
}

// MARK: Tabs

extension ConnectedServerView {
  private var windowTabs: WindowTabs {
    WindowTabs(
      session: session, context: tabContext, showAll: { showsTabOverview = true },
      fail: { tabFailure = $0 }, supportsSplit: sizeClass != .compact)
  }

  private var tabFailurePresented: Binding<Bool> {
    Binding(get: { tabFailure != nil }, set: { if !$0 { tabFailure = nil } })
  }

  /// The session whose chat is on screen, for notification suppression.
  private var viewedSessionID: String? {
    if case .chat(let id) = session.tabs.selected?.content { return id }
    return nil
  }

  /// The selected tab's content, or each pane's in a split window, and the new-tab page when no
  /// tab is open.
  @ViewBuilder private var tabDetail: some View {
    let tabs = session.tabs
    let routes = windowTabs
    if tabs.selected != nil {
      TabSplitView(split: tabs.splitState, actions: routes.actions) { pane in
        if let tab = paneTab(pane) {
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
      case .chat, .newSession, .inbox, .canvas:
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
          })
      }
    }
    .id(tab.id)
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
  private func showInPlace(_ sessionID: String) {
    session.tabs.navigate(to: .chat(sessionID: sessionID)) { content in
      if case .chat = content { return true }
      return false
    }
  }
}

/// A sidebar change the user can undo from the undo bar.
struct SidebarUndo: Identifiable {
  enum Change {
    case pin(String, Bool)
    case archive([String], Bool)
  }

  let id = UUID().uuidString
  let change: Change

  var banner: UndoBanner? {
    switch change {
    case .pin(_, let pinned): UndoBanner(id: id, kind: pinned ? .pinned : .unpinned)
    case .archive(let ids, true): UndoBanner(id: id, kind: .archived(count: ids.count))
    case .archive(_, false): nil
    }
  }

  var inverse: Change {
    switch change {
    case .pin(let id, let pinned): .pin(id, !pinned)
    case .archive(let ids, let archived): .archive(ids, !archived)
    }
  }
}
