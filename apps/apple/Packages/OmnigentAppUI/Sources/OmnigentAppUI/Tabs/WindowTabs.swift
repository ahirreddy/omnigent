public import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentTerminalStores
import OmnigentUIComponents

/// What a window gives its tabs: its id, where tabs are saved, the browser, and tear-off.
public struct TabWindowContext {
  /// The window's stable id (on the Mac, `ServerWindowID.instance`).
  public var window: UUID
  /// Saves and restores the window's tabs; `nil` keeps them in memory.
  public var persistence: TabPersistence?
  /// The browser for browser tabs; `nil` offers no Browser.
  public var browser: (any BrowserTabHosting)?
  /// Opens tabs in a new window on the same server; `nil` where the platform has no windows.
  public var moveToNewWindow: (@MainActor ([AppTab]) -> Void)?
  /// Tabs handed to this window by a tear-off; they replace any saved tabs.
  public var adopting: [AppTab]

  /// Creates a context.
  /// - Parameters:
  ///   - window: The window id.
  ///   - persistence: Tab saving.
  ///   - browser: The browser host.
  ///   - moveToNewWindow: Tear-off.
  ///   - adopting: Torn-off tabs for this window.
  public init(
    window: UUID = UUID(), persistence: TabPersistence? = nil,
    browser: (any BrowserTabHosting)? = nil,
    moveToNewWindow: (@MainActor ([AppTab]) -> Void)? = nil, adopting: [AppTab] = []
  ) {
    self.window = window
    self.persistence = persistence
    self.browser = browser
    self.moveToNewWindow = moveToNewWindow
    self.adopting = adopting
  }
}

/// The tab strip, overview, new-tab page and menu commands of one connected window, over its
/// ``TabStore``.
struct WindowTabs {
  let session: ServerSession
  let context: TabWindowContext
  /// Called when the overview should show (Show All Tabs).
  let showAll: @MainActor () -> Void
  /// Reports a failure to the window (a terminal that could not start).
  let fail: @MainActor (String) -> Void
  /// The window is wide enough to split (not a compact width).
  var supportsSplit = true

  var store: TabStore { session.tabs }
  var browser: (any BrowserTabHosting)? { context.browser }

  /// The strip's state.
  var state: TabsState {
    TabAdapter.state(
      store, session: session, browser: browser,
      issue: context.persistence?.issue?.description)
  }

  /// The strip's actions.
  var actions: TabActions {
    let store = store
    var actions = TabActions(
      select: { store.select($0) },
      close: { store.requestClose($0) },
      newTab: { store.open(.newTab) },
      move: { store.move($0, to: $1) },
      setPinned: { store.setPinned($0, $1) },
      duplicate: { duplicate($0) },
      closeOthers: { store.closeOthers($0) },
      closeToRight: { store.closeToRight($0) })
    if !store.closed.isEmpty {
      actions.reopenClosed = { store.reopenClosed() }
    }
    if context.moveToNewWindow != nil {
      actions.moveToNewWindow = { moveToNewWindow($0) }
    }
    if supportsSplit {
      actions.showInPane = { store.show($0, in: $1) }
      actions.focusPane = { store.focus($0) }
      actions.setSplitFraction = { store.setSplitFraction($0) }
      actions.closeSplit = { store.closeSplit() }
    }
    if session.remoteBrowsers != nil {
      actions.newRemoteBrowser = { profile in
        guard let sessionID = remoteBrowserSession else {
          fail("Open a session first: a remote browser runs on a session's machine.")
          return
        }
        Task { await openRemoteBrowser(in: sessionID, profile: profile, replacing: nil) }
      }
      actions.remoteBrowserProfiles = remoteBrowserProfiles
    }
    return actions
  }

  /// The session a remote browser opened from the + menu belongs to: the selected tab's, else
  /// the most recently active one.
  private var remoteBrowserSession: String? {
    store.selected?.content.sessionID
      ?? session.connection.sessionList.visible.max { $0.updatedAt < $1.updatedAt }?.id
  }

  /// Profile names read for any session (profiles are per machine).
  private var remoteBrowserProfiles: [String] {
    let profiles = session.remoteBrowsers?.profiles ?? [:]
    let names = profiles.values.flatMap { $0.map(\.name) }
    return Array(Set(names)).sorted { $0 == "default" || ($1 != "default" && $0 < $1) }
  }

  /// The menu commands.
  var commands: TabCommandActions {
    let store = store
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
        commands.duplicateTab = { duplicate(selected.id) }
      }
      if context.moveToNewWindow != nil, store.canClose(selected.id) {
        commands.moveTabToNewWindow = { moveToNewWindow(selected.id) }
      }
      if supportsSplit {
        let target = store.pane(of: selected.id)?.other ?? .trailing
        commands.moveTabToOtherPane = { store.show(selected.id, in: target) }
      }
    }
    if supportsSplit {
      commands.supportsSplit = true
      commands.isSplit = store.split != nil
      if !store.tabs.isEmpty { commands.toggleSplit = { store.toggleSplit() } }
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
      commands.openBrowser = { openBrowser() }
    }
    if let selected, let sessionID = selected.content.sessionID,
      Self.offersTerminal(selected.content)
    {
      commands.toggleTerminal = { toggleTerminal(sessionID) }
    }
    return commands
  }

  /// The new-tab page's state.
  var newTabState: NewTabPageState {
    let list = session.connection.sessionList
    let recent = list.visible.sorted { $0.updatedAt > $1.updatedAt }.prefix(12).map {
      OmnigentUIComponents.SessionSummary($0, attention: list.attention(of: $0.id))
    }
    var names: [String: [String]] = [:]
    for summary in recent {
      if case .names(let declared) = session.declaredTerminalNames(in: summary.id) {
        names[summary.id] = declared
      }
    }
    return NewTabPageState(
      recentSessions: Array(recent), canOpenBrowser: browser != nil, terminalNames: names,
      remoteBrowserProfiles: remoteBrowserProfiles)
  }

  /// The new-tab page's actions; each replaces the tab `id` (or opens one when `nil`).
  /// - Parameter id: The new-tab page's tab.
  /// - Returns: The actions.
  func newTabActions(replacing id: String?) -> NewTabPageActions {
    let store = store
    func show(_ content: AppTabContent, browserState: Data? = nil) {
      if let id {
        store.replace(id, with: content, browserState: browserState)
      } else {
        store.open(content, browserState: browserState)
      }
    }
    var actions = NewTabPageActions(
      newSession: { show(.newSession) },
      openSession: { show(.chat(sessionID: $0)) })
    actions.newTerminal = { sessionID, name in
      Task { await newTerminal(in: sessionID, named: name, replacing: id) }
    }
    if let browser {
      actions.openBrowser = {
        let page = browser.makePage(url: session.connectedURL)
        show(.browser(browserID: page.id), browserState: page.state)
      }
    }
    if session.remoteBrowsers != nil {
      actions.openRemoteBrowser = { sessionID, profile in
        Task { await openRemoteBrowser(in: sessionID, profile: profile, replacing: id) }
      }
    }
    return actions
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
    let content = AppTabContent.remoteBrowser(sessionID: sessionID, tabID: opened.tab.id)
    if let id, store.tab(id) != nil {
      store.replace(id, with: content, browserState: record)
    } else {
      store.open(content, browserState: record)
    }
  }

  /// Opens a browser tab at `url` (the server's web app by default).
  /// - Parameter url: The page.
  func openBrowser(url: URL? = nil) {
    guard let browser else { return }
    let page = browser.makePage(url: url ?? session.connectedURL)
    store.navigate(to: .browser(browserID: page.id))
    if let tab = store.selected { store.record(tab.id, title: nil, browserState: page.state) }
  }

  /// Opens a session's harness TUI in a tab.
  /// - Parameter sessionID: The session.
  func openHarness(_ sessionID: String) {
    store.open(.harness(sessionID: sessionID))
  }

  /// Opens one of a session's terminals in a tab.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - terminalID: The terminal.
  func openTerminal(_ sessionID: String, _ terminalID: String) {
    store.open(.terminal(sessionID: sessionID, terminalID: terminalID))
  }

  /// Opens a side question in a tab.
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - rowID: The transcript row.
  ///   - title: The question, for the strip.
  func openSideChat(_ sessionID: String, rowID: String, title: String?) {
    store.open(.sideChat(sessionID: sessionID, rowID: rowID), title: title)
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
    switch store.selected?.content {
    case .terminal, .harness:
      store.open(.chat(sessionID: sessionID))
    default:
      let terminals = session.terminalStores[sessionID]?.terminals
      if case .ready = terminals?.harness {
        openHarness(sessionID)
      } else if let shell = terminals?.userShells.first {
        openTerminal(sessionID, shell.terminal.id)
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
    let content = AppTabContent.terminal(sessionID: sessionID, terminalID: created.id)
    if let id {
      store.replace(id, with: content)
    } else {
      store.open(content)
    }
  }

  private func duplicate(_ id: String) {
    guard let tab = store.tab(id) else { return }
    if case .browser(let pageID) = tab.content {
      guard let browser else { return }
      let page = browser.makePage(url: browser.status(of: pageID)?.url)
      store.duplicate(id, browser: page)
    } else {
      store.duplicate(id)
    }
  }

  private func moveToNewWindow(_ id: String) {
    guard let move = context.moveToNewWindow, let tab = store.detach(id) else { return }
    if case .remoteBrowser(let sessionID, let tabID) = tab.content {
      // The new window attaches its own stream; the remote tab stays open.
      session.remoteBrowsers?.detach(sessionID: sessionID, tabID: tabID)
    }
    move([tab])
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
  /// Another session's chat (a sub-agent or the parent), focused when already open, else
  /// opened right after this tab.
  var openSession: @MainActor (String) -> Void
  /// Starts a terminal (a declared name, or the default) and opens it in a tab.
  var newTerminal: (@MainActor (String?) -> Void)?
  /// Opens a browser tab; `nil` when the window has no browser.
  var openBrowser: (@MainActor () -> Void)?
}

extension WindowTabs {
  /// The routes for `sessionID`'s conversation.
  func routes(for sessionID: String) -> ConversationTabRoutes {
    let store = store
    var routes = ConversationTabRoutes(
      openHarness: { openHarness(sessionID) },
      openTerminal: { openTerminal(sessionID, $0) },
      openSideChat: { openSideChat(sessionID, rowID: $0, title: $1) },
      openSession: { store.open(.chat(sessionID: $0)) })
    routes.newTerminal = { name in
      Task { await newTerminal(in: sessionID, named: name, replacing: nil) }
    }
    if let browser {
      let session = session
      routes.openBrowser = {
        let page = browser.makePage(url: session.connectedURL)
        store.open(.browser(browserID: page.id), browserState: page.state)
      }
    }
    return routes
  }
}
