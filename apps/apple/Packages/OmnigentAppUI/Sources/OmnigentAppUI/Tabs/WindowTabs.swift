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
  /// Where the remembered terminal (``PreferredTerminal``) is read.
  var preferences = UserDefaults.standard

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
    // What the New Tab page offers, each in a new tab; read when + draws, not with the strip.
    actions.newTabMenu = {
      NewTabOptions(state: newTabState, actions: newTabActions(replacing: nil))
    }
    return actions
  }

  /// Profile names, the default first, once each.
  private static func profileNames(_ names: [String]) -> [String] {
    Array(Set(names)).sorted { $0 == "default" || ($1 != "default" && $0 < $1) }
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

  /// The new-tab page's and the + menu's state: what the shown session offers.
  var newTabState: NewTabPageState {
    guard let current = groups.currentSessionID else { return NewTabPageState() }
    let terminals: NewTabTerminals =
      switch session.declaredTerminalNames(in: current) {
      case .unknown: .unknown
      case .names(let declared): .declared(declared)
      }
    let profiles = session.remoteBrowsers?.profiles[current] ?? []
    return NewTabPageState(
      sessionTitle: session.connection.sessionList.sessionWithoutActivity(current)?.title,
      canOpenBrowser: browser != nil, terminals: terminals,
      remoteBrowserProfiles: Self.profileNames(profiles.map(\.name)))
  }

  /// The new-tab page's actions. Each replaces the page's tab `id` (or opens one when `nil`)
  /// in the shown session.
  /// - Parameter id: The new-tab page's tab.
  /// - Returns: The actions.
  func newTabActions(replacing id: String?) -> NewTabPageActions {
    var actions = NewTabPageActions()
    guard let current = groups.currentSessionID else { return actions }
    if let conversation = session.connection.openConversation(current),
      SessionToolsAdapter.offersSideChat(conversation)
    {
      actions.newSideChat = { startSideChat(conversation, in: current, replacing: id) }
    }
    actions.newTerminal = { name in
      Task { await newTerminal(in: current, named: name, replacing: id) }
    }
    if let browser {
      actions.openBrowser = {
        let page = browser.makePage(url: session.connectedURL)
        show(
          .browser(browserID: page.id), in: current, replacing: id, browserState: page.state)
      }
    }
    if session.remoteBrowsers != nil {
      actions.openRemoteBrowser = { profile in
        Task { await openRemoteBrowser(in: current, profile: profile, replacing: id) }
      }
    }
    return actions
  }

  /// Starts a side chat from the new-tab page: a new side chat in the page's tab, or for a
  /// native harness, its chat with `/side` in the composer.
  private func startSideChat(
    _ conversation: ConversationStore, in sessionID: String, replacing id: String?
  ) {
    let harness = conversation.header?.settings?.harness
    switch OmnigentCoreFFI.sideChatStart(harness: harness, quote: nil) {
    case .command(let prefix):
      if let id { groups.group(sessionID).close(id) }
      groups.showChat(sessionID)
      guard conversation.composer.text.isEmpty else {
        fail("Send or clear the message you are writing before starting a side chat.")
        return
      }
      conversation.composer.text = prefix
    case .draft(let draft):
      openPendingSideChat(sessionID, draft: draft, sendNow: false, replacing: id)
    }
  }

  /// Shows `content` in a session's group, in the tab `id` when it is still open there, else
  /// in a new tab, and shows the session.
  @discardableResult
  func show(
    _ content: AppTabContent, in sessionID: String, replacing id: String?,
    browserState: Data? = nil
  ) -> AppTab? {
    let group = groups.group(sessionID)
    let tab =
      if let id, group.tab(id) != nil {
        group.replace(id, with: content, browserState: browserState)
      } else {
        group.open(content, browserState: browserState)
      }
    groups.show(.session(sessionID))
    return tab
  }

  /// Creates a remote browser tab on a session's machine and shows it, replacing the tab `id`
  /// (or opening one when `nil`).
  /// - Parameters:
  ///   - sessionID: The session.
  ///   - profile: The browser profile.
  ///   - url: The first page; the host's default when `nil`.
  ///   - id: The tab to replace.
  ///   - encode: Makes the state the tab saves.
  func openRemoteBrowser(
    in sessionID: String, profile: String, url: String? = nil, replacing id: String?,
    encode: (RemoteBrowserTabRecord) throws -> Data = { try $0.encoded() }
  ) async {
    guard let remote = session.remoteBrowsers else { return }
    guard let opened = await remote.open(sessionID: sessionID, url: url, profile: profile) else {
      fail(remote.lastError ?? "The remote browser tab could not be created.")
      return
    }
    let record: Data
    do {
      record = try encode(opened.record)
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
    case .chat, .terminal: true
    default: false
    }
  }

  /// Control-`: from a session's chat to its terminal (the harness TUI in the chat's Terminal
  /// view, else its first shell), and from a terminal back to the chat.
  func toggleTerminal(_ sessionID: String) {
    switch groups.group(sessionID).selected?.content {
    case .terminal:
      open(.chat(sessionID: sessionID))
    default:
      let terminals = session.terminals(of: sessionID)?.terminals
      if case .ready = terminals?.harness {
        groups.setViewMode(
          groups.viewMode(sessionID) == .terminal ? .chat : .terminal, for: sessionID)
      } else if let shell = terminals?.userShells.first {
        open(.terminal(sessionID: sessionID, terminalID: shell.terminal.id))
      } else {
        Task { await newTerminal(in: sessionID, named: nil, replacing: nil) }
      }
    }
  }

  /// Starts a terminal in a session and shows it in a tab: `name`, else the remembered one the
  /// agent declares, else its first (the host's login shell for a native harness), else the
  /// conventional "Shell" while the declared names are unknown.
  func newTerminal(in sessionID: String, named name: String?, replacing id: String?) async {
    session.open(sessionID)
    guard let terminals = session.terminals(of: sessionID)?.terminals else {
      fail("The session's terminals are not available.")
      return
    }
    await session.loadDeclaredTerminalNames([sessionID])
    let choices = session.declaredTerminalNames(in: sessionID).choices
    let preferred = PreferredTerminal.stored(in: preferences)
    guard let chosen = name ?? PreferredTerminal.resolve(choices, preferred: preferred) else {
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
