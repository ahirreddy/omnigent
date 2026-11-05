public import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentTerminalStores
import OmnigentUIComponents

/// What a window gives its tabs: its id, where tabs are saved, and the browser.
public struct TabWindowContext {
  /// The window's stable id (on the Mac, `ServerWindowID.instance`).
  public var window: UUID
  /// Saves and restores the sessions' tabs and the window's page; `nil` keeps them in memory.
  public var persistence: TabPersistence?
  /// The browser for browser tabs; `nil` offers no Browser.
  public var browser: (any BrowserTabHosting)?

  /// Creates a context.
  /// - Parameters:
  ///   - window: The window id.
  ///   - persistence: Tab saving.
  ///   - browser: The browser host.
  public init(
    window: UUID = UUID(), persistence: TabPersistence? = nil,
    browser: (any BrowserTabHosting)? = nil
  ) {
    self.window = window
    self.persistence = persistence
    self.browser = browser
  }
}

/// The tab strip, overview, new-tab page and menu commands of one connected window, over the
/// shown session's ``TabStore`` in ``SessionTabGroups``.
struct WindowTabs {
  let session: ServerSession
  let context: TabWindowContext
  /// Called when the overview should show (Show All Tabs).
  let showAll: @MainActor () -> Void
  /// Reports a failure to the window (a terminal that could not start).
  let fail: @MainActor (String) -> Void
  /// The window is wide enough to split (not a compact width).
  var supportsSplit = true
  /// Opens a session in another window, where the platform has windows.
  var openInNewWindow: (@MainActor (String) -> Void)?

  var groups: SessionTabGroups { session.tabs }
  /// The shown session's tabs; `nil` on a session-less page.
  var store: TabStore? { groups.current }
  var browser: (any BrowserTabHosting)? { context.browser }

  /// The strip's state and actions, for the shown session; `nil` on a session-less page.
  var strip: (state: TabsState, actions: TabActions)? {
    guard let store else { return nil }
    return (state(store), actions(store))
  }

  /// The strip's state.
  func state(_ store: TabStore) -> TabsState {
    TabAdapter.state(
      store, session: session, browser: browser,
      issue: context.persistence?.issue?.description)
  }

  /// The strip's actions.
  func actions(_ store: TabStore) -> TabActions {
    var actions = TabActions(
      select: { store.select($0) },
      close: { store.requestClose($0) },
      newTab: { store.open(.newTab) },
      move: { store.move($0, to: $1) },
      setPinned: { store.setPinned($0, $1) },
      duplicate: { duplicate($0, in: store) },
      closeOthers: { store.closeOthers($0) },
      closeToRight: { store.closeToRight($0) })
    if !store.closed.isEmpty {
      actions.reopenClosed = { store.reopenClosed() }
    }
    if supportsSplit {
      actions.showInPane = { store.show($0, in: $1) }
      actions.focusPane = { store.focus($0) }
      actions.setSplitFraction = { store.setSplitFraction($0) }
      actions.closeSplit = { store.closeSplit() }
    }
    if session.remoteBrowsers != nil, let sessionID = groups.currentSessionID {
      actions.newRemoteBrowser = { profile in
        Task { await openRemoteBrowser(in: sessionID, profile: profile, replacing: nil) }
      }
      actions.remoteBrowserProfiles = remoteBrowserProfiles
    }
    return actions
  }

  /// Profile names read for any session (profiles are per machine).
  private var remoteBrowserProfiles: [String] {
    let profiles = session.remoteBrowsers?.profiles ?? [:]
    let names = profiles.values.flatMap { $0.map(\.name) }
    return Array(Set(names)).sorted { $0 == "default" || ($1 != "default" && $0 < $1) }
  }

  /// The menu commands: the shown session's tabs, or New Tab going to New Session on a
  /// session-less page.
  var commands: TabCommandActions {
    let groups = groups
    guard let store, let sessionID = groups.currentSessionID else {
      return TabCommandActions(
        newTab: { groups.show(.newSession) }, selectTab: { _ in }, showAllTabs: nil, count: 0)
    }
    let selected = store.selected
    var commands = TabCommandActions(
      newTab: { store.open(.newTab) },
      selectTab: { store.select(position: $0) },
      showAllTabs: showAll,
      count: store.tabs.count)
    if let selected {
      // A primary chat leaves only with its session, so Close Tab is disabled on it.
      if store.canClose(selected.id) {
        commands.closeTab = { store.requestClose(selected.id) }
      }
      commands.togglePinned = { store.setPinned(selected.id, !selected.isPinned) }
      if TabAdapter.item(selected, session: session, browser: nil).canDuplicate {
        commands.duplicateTab = { duplicate(selected.id, in: store) }
      }
      if supportsSplit {
        let target = store.pane(of: selected.id)?.other ?? .trailing
        commands.moveTabToOtherPane = { store.show(selected.id, in: target) }
      }
    }
    if supportsSplit {
      commands.supportsSplit = true
      commands.isSplit = store.split != nil
      commands.toggleSplit = { store.toggleSplit() }
      if store.split != nil { commands.focusPane = { store.focus($0) } }
    }
    if !store.closed.isEmpty {
      commands.reopenClosedTab = { store.reopenClosed() }
    }
    if store.tabs.count > 1 {
      commands.selectNextTab = { store.selectNext() }
      commands.selectPreviousTab = { store.selectPrevious() }
    }
    if browser != nil {
      commands.openBrowser = { openBrowser(in: sessionID) }
    }
    if let selected, Self.offersTerminal(selected.content) {
      commands.toggleTerminal = { toggleTerminal(sessionID) }
    }
    commands.newShell = { Task { await newTerminal(in: sessionID, named: nil, replacing: nil) } }
    return commands
  }

  /// The new-tab page's state: the shown session first, then the other recent ones.
  var newTabState: NewTabPageState {
    let list = session.connection.sessionList
    let current = groups.currentSessionID
    let others = list.visible.filter { $0.id != current }.sorted { $0.updatedAt > $1.updatedAt }
    let ordered = (current.flatMap(list.session).map { [$0] } ?? []) + others.prefix(11)
    let recent = ordered.map {
      OmnigentUIComponents.SessionSummary($0, attention: list.attention(of: $0.id))
    }
    var names: [String: [String]] = [:]
    for summary in recent {
      if case .names(let declared) = session.declaredTerminalNames(in: summary.id) {
        names[summary.id] = declared
      }
    }
    return NewTabPageState(
      recentSessions: recent, canOpenBrowser: browser != nil, terminalNames: names,
      remoteBrowserProfiles: remoteBrowserProfiles)
  }

  /// The new-tab page's actions. Each replaces the page's tab `id` (or opens one when `nil`)
  /// in the shown session; what belongs elsewhere (another session, New Session) closes the
  /// page and shows it there.
  /// - Parameter id: The new-tab page's tab.
  /// - Returns: The actions.
  func newTabActions(replacing id: String?) -> NewTabPageActions {
    let groups = groups
    let current = groups.currentSessionID
    /// The page's tab when `sessionID` is the shown session; otherwise the page closes.
    func target(_ sessionID: String) -> String? {
      guard let id, sessionID == current else {
        if let id { groups.current?.close(id) }
        return nil
      }
      return id
    }
    var actions = NewTabPageActions(
      newSession: {
        if let id { groups.current?.close(id) }
        groups.show(.newSession)
      },
      openSession: { sessionID in
        if let id { groups.current?.close(id) }
        groups.showChat(sessionID)
      })
    actions.newTerminal = { sessionID, name in
      let replacing = target(sessionID)
      Task { await newTerminal(in: sessionID, named: name, replacing: replacing) }
    }
    if let browser, let current {
      actions.openBrowser = {
        let page = browser.makePage(url: session.connectedURL)
        show(
          .browser(browserID: page.id), in: current, replacing: id, browserState: page.state)
      }
    }
    if session.remoteBrowsers != nil {
      actions.openRemoteBrowser = { sessionID, profile in
        let replacing = target(sessionID)
        Task { await openRemoteBrowser(in: sessionID, profile: profile, replacing: replacing) }
      }
    }
    return actions
  }

  /// Shows `content` in a session's group, in the tab `id` when it is still open there, else
  /// in a new tab, and shows the session.
  func show(
    _ content: AppTabContent, in sessionID: String, replacing id: String?,
    browserState: Data? = nil
  ) {
    let group = groups.group(sessionID)
    if let id, group.tab(id) != nil {
      group.replace(id, with: content, browserState: browserState)
    } else {
      group.open(content, browserState: browserState)
    }
    groups.show(.session(sessionID))
  }

  /// Creates a remote browser tab on a session's machine and shows it, replacing the tab `id`
  /// (or opening one when `nil`).
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - profile: The browser profile.
  ///   - url: The first page; the host's default when `nil`.
  ///   - id: The tab to replace.
  func openRemoteBrowser(
    in sessionID: String, profile: String, url: String? = nil, replacing id: String?
  ) async {
    guard let remote = session.remoteBrowsers else { return }
    guard let opened = await remote.open(sessionID: sessionID, url: url, profile: profile) else {
      fail(remote.lastError ?? "The remote browser tab could not be created.")
      return
    }
    let record: Data
    do {
      record = try opened.record.encoded()
    } catch {
      fail("The remote browser tab could not be saved: \(error)")
      return
    }
    show(
      .remoteBrowser(sessionID: sessionID, tabID: opened.tab.id), in: sessionID, replacing: id,
      browserState: record)
  }

  /// Opens a browser tab at `url` (the server's web app by default) in a session's tabs.
  /// - Parameters:
  ///   - url: The page.
  ///   - sessionID: The session it opens from.
  func openBrowser(url: URL? = nil, in sessionID: String) {
    guard let browser else { return }
    let page = browser.makePage(url: url ?? session.connectedURL)
    groups.group(sessionID).open(.browser(browserID: page.id), browserState: page.state)
    groups.show(.session(sessionID))
  }

  /// Opens a session's tab, focusing it when it is one per session.
  func open(_ content: AppTabContent, title: String? = nil) {
    groups.open(content, title: title)
  }

  /// Whether Show Terminal (Control-`) applies: from a session's primary chat to its terminal,
  /// and from a terminal back. Side chats and browsers have no terminal view.
  static func offersTerminal(_ content: AppTabContent) -> Bool {
    switch content {
    case .chat, .terminal, .harness: true
    default: false
    }
  }

  /// Control-`: from a session's chat to its terminal (the harness TUI, else its first shell),
  /// and from a terminal back to the chat.
  func toggleTerminal(_ sessionID: String) {
    switch groups.group(sessionID).selected?.content {
    case .terminal, .harness:
      open(.chat(sessionID: sessionID))
    default:
      let terminals = session.terminalStores[sessionID]?.terminals
      if case .ready = terminals?.harness {
        open(.harness(sessionID: sessionID))
      } else if let shell = terminals?.userShells.first {
        open(.terminal(sessionID: sessionID, terminalID: shell.terminal.id))
      } else {
        Task { await newTerminal(in: sessionID, named: nil, replacing: nil) }
      }
    }
  }

  /// Starts a terminal in a session and shows it in a tab: `name`, else the agent's only
  /// declared terminal, else the conventional "Shell" while the declared names are unknown.
  func newTerminal(in sessionID: String, named name: String?, replacing id: String?) async {
    session.open(sessionID)
    guard let terminals = session.terminalStores[sessionID]?.terminals else {
      fail("The session's terminals are not available.")
      return
    }
    await session.loadDeclaredTerminalNames([sessionID])
    let choices = session.declaredTerminalNames(in: sessionID).choices
    guard let chosen = name ?? choices.first else {
      fail("This session's agent declares no terminals, so none can start here.")
      return
    }
    guard let created = await terminals.create(chosen) else {
      fail(terminals.lastError?.message ?? "The terminal could not start.")
      return
    }
    show(
      .terminal(sessionID: sessionID, terminalID: created.id), in: sessionID, replacing: id)
  }

  private func duplicate(_ id: String, in store: TabStore) {
    guard let tab = store.tab(id) else { return }
    if case .browser(let pageID) = tab.content {
      guard let browser else { return }
      let page = browser.makePage(url: browser.status(of: pageID)?.url)
      store.duplicate(id, browser: page)
    } else {
      store.duplicate(id)
    }
  }
}

extension AppTabContent {
  /// The page id of a browser tab.
  var browserID: UUID? {
    if case .browser(let id) = self { return id }
    return nil
  }
}

/// How a conversation opens its session's other tabs.
struct ConversationTabRoutes {
  /// The agent's TUI.
  var openHarness: @MainActor () -> Void
  /// A terminal by id.
  var openTerminal: @MainActor (String) -> Void
  /// A side question by transcript row id, with the question as its title.
  var openSideChat: @MainActor (String, String?) -> Void
  /// Another session (a sub-agent or the parent): the window shows it with its tabs.
  var openSession: @MainActor (String) -> Void
  /// A sub-agent's chat, when it opens elsewhere than `openSession` (a window of its own).
  var openChild: (@MainActor (String) -> Void)?
  /// Starts a terminal (a declared name, or the default) and opens it in a tab.
  var newTerminal: (@MainActor (String?) -> Void)?
  /// Opens a browser tab; `nil` when the window has no browser.
  var openBrowser: (@MainActor () -> Void)?
  /// A terminal-backed chat showed: opens its terminal the first time, per Settings.
  var applyDefaultView: (@MainActor () -> Void)?
}

extension WindowTabs {
  /// The routes for `sessionID`'s conversation: its tabs open in its own group.
  func routes(for sessionID: String) -> ConversationTabRoutes {
    let groups = groups
    var routes = ConversationTabRoutes(
      openHarness: { groups.open(.harness(sessionID: sessionID)) },
      openTerminal: { groups.open(.terminal(sessionID: sessionID, terminalID: $0)) },
      openSideChat: { groups.open(.sideChat(sessionID: sessionID, rowID: $0), title: $1) },
      openSession: { groups.show(.session($0)) })
    routes.newTerminal = { name in
      Task { await newTerminal(in: sessionID, named: name, replacing: nil) }
    }
    if browser != nil {
      routes.openBrowser = { openBrowser(in: sessionID) }
    }
    return routes
  }
}
