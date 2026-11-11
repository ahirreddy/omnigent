public import Foundation
public import Observation
public import OmnigentUIComponents

/// A window's tabs, scoped per session. Each session owns a ``TabStore``: its primary chat, side
/// chats, terminals and the browser tabs opened from it. The window shows one page:
/// a session, with its tabs in the strip, or a session-less page (New Session, Inbox, Canvas,
/// Automations, Usage) at full size with no strip. Showing another session swaps the whole strip;
/// coming back shows its tabs as they were, the selected one included.
///
/// A session's group is made the first time it shows here, from its saved tabs (``loadSaved``,
/// which may be another window's) or with just its primary chat, and stays for the window's
/// life. The few most recently shown sessions stay open (``liveSessionIDs``), and their recently
/// shown chats stay built (``keptAlive(limit:)``), so switching back is immediate.
@Observable
public final class SessionTabGroups {
  /// How many recently shown sessions stay open (conversation, terminals, workspace) unless a
  /// window says otherwise: the session groups a Mac window's owner moves among, each a stream
  /// from the server, and fewer where memory is tighter.
  public static let liveLimit: Int = {
    #if os(macOS)
      return 6
    #else
      return 3
    #endif
  }()

  /// How many recently shown sessions this window keeps open.
  @ObservationIgnored public var liveLimit = SessionTabGroups.liveLimit

  /// What the window shows: a session's tabs or a session-less page; `nil` for nothing.
  public private(set) var page: SidebarDestination?
  /// Each session's tabs, made the first time the session shows in this window.
  public private(set) var groups: [String: TabStore] = [:]
  /// Sessions in the order they were last shown, the most recent first.
  public private(set) var recentSessions: [String] = []
  /// Tabs in the order they were last shown, across sessions, the most recent first.
  @ObservationIgnored private(set) var recentTabs: [String] = []
  /// Each chat's Chat or Terminal choice, by session (see ``viewChoice(_:)``).
  @ObservationIgnored var viewChoices: [String: SessionViewChoice] = [:]

  /// Reads a session's saved tabs when its group is made.
  @ObservationIgnored public var loadSaved: (@MainActor (String) -> TabWindowSnapshot?)?
  /// Whether a browser page is already shown by another window, so a group made from saved tabs
  /// gives that tab a page of its own.
  @ObservationIgnored public var pageInUse: (@MainActor (UUID) -> Bool)?
  /// Called after the page or a group changes, with the group's session.
  @ObservationIgnored public var onChange: (@MainActor (String?) -> Void)?
  /// Called with sessions whose groups left (archived or deleted), so their saved tabs go too.
  @ObservationIgnored public var onRemove: (@MainActor (Set<String>) -> Void)?
  /// See ``TabStore/willClose``; applies to every group.
  @ObservationIgnored public var willClose: (@MainActor (AppTab) -> AppTab)? {
    didSet { for group in groups.values { group.willClose = willClose } }
  }

  /// Creates an empty window.
  public init() {}

  /// The shown session's tabs; `nil` on a session-less page.
  public var current: TabStore? { page?.sessionID.flatMap { groups[$0] } }

  /// The shown session.
  public var currentSessionID: String? { page?.sessionID }

  /// The tabs of the session shown last: the shown session's, and still that session's under a
  /// session-less page, so the titlebar's strip has nothing to read when a page covers it.
  public var lastShown: TabStore? { recentSessions.first.flatMap { groups[$0] } }

  /// The selected tab of the shown session.
  public var selected: AppTab? { current?.selected }

  /// Sessions to keep open: the shown one and the most recently shown others, with the side
  /// chats their built tabs show.
  public var liveSessionIDs: Set<String> {
    let recent = recentSessions.prefix(liveLimit)
    return recent.reduce(into: Set(recent)) { live, sessionID in
      live.formUnion(groups[sessionID]?.liveSessionIDs ?? [])
    }
  }

  /// A tab of any session, with its session.
  /// - Parameter id: The tab.
  /// - Returns: The session and the tab.
  public func tab(_ id: String) -> (sessionID: String, tab: AppTab)? {
    for (sessionID, group) in groups {
      if let tab = group.tab(id) { return (sessionID, tab) }
    }
    return nil
  }

  // MARK: Showing

  /// Shows a page: a session's tabs (made on first show) or a session-less page.
  /// - Parameter destination: The page; `nil` shows nothing.
  public func show(_ destination: SidebarDestination?) {
    if let sessionID = destination?.sessionID { _ = group(sessionID) }
    guard page != destination else { return }
    page = destination
    if let sessionID = destination?.sessionID { noteShown(sessionID) }
    onChange?(nil)
  }

  /// Shows a session with its primary chat selected, as links to its conversation do.
  /// - Parameter sessionID: The session.
  public func showChat(_ sessionID: String) {
    group(sessionID).open(.chat(sessionID: sessionID))
    show(.session(sessionID))
  }

  /// Opens `content` in its session's group (the shown session's, for a browser or new-tab
  /// page) and shows that session; a session-less page is shown instead.
  /// - Parameters:
  ///   - content: What to open.
  ///   - select: Select the tab and show its session.
  ///   - title: A title to show before the content is built.
  ///   - browserState: Browser restore state.
  /// - Returns: The tab, or `nil` for a page or when no session is shown to hold it.
  @discardableResult
  public func open(
    _ content: AppTabContent, select: Bool = true, title: String? = nil,
    browserState: Data? = nil
  ) -> AppTab? {
    if !Self.belongsInGroup(content), let destination = content.destination {
      show(destination)
      return nil
    }
    guard let sessionID = content.sessionID ?? currentSessionID else { return nil }
    let tab = group(sessionID).open(
      content, select: select, title: title, browserState: browserState)
    if select { show(.session(sessionID)) }
    return tab
  }

  /// Selects a tab of any session and shows that session.
  /// - Parameter id: The tab.
  public func select(_ id: String) {
    guard let (sessionID, _) = tab(id) else { return }
    groups[sessionID]?.select(id)
    show(.session(sessionID))
  }

  /// Shows other content in a tab of any session, in place (a new side chat's tab once the side
  /// chat exists).
  /// - Parameters:
  ///   - id: The tab.
  ///   - content: What it shows now.
  public func replace(_ id: String, with content: AppTabContent) {
    guard let (sessionID, _) = tab(id) else { return }
    groups[sessionID]?.replace(id, with: content)
  }

  /// Closes a tab of any session.
  /// - Parameter id: The tab.
  public func close(_ id: String) {
    guard let (sessionID, _) = tab(id) else { return }
    groups[sessionID]?.close(id)
  }

  /// A session's group, made from its saved tabs when it has none yet.
  /// - Parameter sessionID: The session.
  /// - Returns: The group.
  public func group(_ sessionID: String) -> TabStore {
    if let group = groups[sessionID] { return group }
    let loaded = loadSaved?(sessionID)
    // Tabs saved on the agent's terminal, when it had a tab of its own: the chat shows it.
    if let loaded, Self.selectsHarness(loaded) { setViewMode(.terminal, for: sessionID) }
    var saved = Self.normalized(loaded ?? TabWindowSnapshot(), for: sessionID)
    if let pageInUse { saved = Self.reassigningPages(saved, inUse: pageInUse) }
    let group = TabStore(saved)
    group.willClose = willClose
    group.onChange = { [weak self] in self?.groupChanged(sessionID) }
    groups[sessionID] = group
    return group
  }

  // MARK: Removing

  /// Removes sessions' groups without remembering them: the sessions were archived or deleted.
  /// A removed shown session gives way to the most recently shown other one.
  /// - Parameter sessionIDs: The sessions.
  public func removeSessions(_ sessionIDs: Set<String>) {
    for sessionID in sessionIDs {
      if let group = groups.removeValue(forKey: sessionID) { retire(group) }
    }
    recentSessions.removeAll(where: sessionIDs.contains)
    viewChoices = viewChoices.filter { !sessionIDs.contains($0.key) }
    if let shown = currentSessionID, sessionIDs.contains(shown) {
      page = recentSessions.first.map(SidebarDestination.session)
      onChange?(nil)
    }
    onRemove?(sessionIDs)
  }

  /// Drops every group and the page, closing their pages, when the window moves to another
  /// server. Sessions keep their saved tabs.
  public func reset() {
    let previous = groups
    groups = [:]
    for group in previous.values { retire(group) }
    recentSessions = []
    recentTabs = []
    viewChoices = [:]
    if page != nil { page = nil }
  }

  // MARK: Internals

  /// Releases a dropped group's live content (browser pages, remote tabs).
  private func retire(_ group: TabStore) {
    group.onChange = nil
    for tab in group.tabs { _ = group.retire(tab) }
  }

  private func groupChanged(_ sessionID: String) {
    if sessionID == currentSessionID, let current { noteShownTabs(of: current) }
    onChange?(sessionID)
  }

  /// Puts a session's shown tabs first in ``recentTabs``: a split's other pane counts as
  /// shown as recently as the focused one, so both stay built when another session shows.
  private func noteShownTabs(of group: TabStore) {
    for tab in group.shownTabs.reversed() { noteTab(tab.id) }
  }

  private func noteShown(_ sessionID: String) {
    let group = group(sessionID)
    if recentSessions.first != sessionID {
      // A session that closed has nothing built: its hidden tabs wait until they show.
      if !liveSessionIDs.contains(sessionID) {
        recentTabs.removeAll(where: Set(group.tabs.map(\.id)).contains)
      }
      recentSessions.removeAll { $0 == sessionID }
      recentSessions.insert(sessionID, at: 0)
    }
    noteShownTabs(of: group)
  }

  private func noteTab(_ id: String) {
    guard recentTabs.first != id else { return }
    recentTabs.removeAll { $0 == id }
    recentTabs.insert(id, at: 0)
    if recentTabs.count > 32 { recentTabs.removeLast(recentTabs.count - 32) }
  }
}

extension SessionTabGroups {
  /// Whether a tab of this kind lives in a session's group: the session's own tabs, browser
  /// pages and the new-tab page. Session-less pages show at full size instead, and the agent's
  /// terminal shows in the session's chat.
  nonisolated static func belongsInGroup(_ content: AppTabContent) -> Bool {
    switch content {
    case .newSession, .inbox, .canvas, .automations, .usage, .harness: false
    case .newTab, .chat, .terminal, .sideChat, .sideChatSession, .browser, .agentBrowser,
      .remoteBrowser:
      true
    }
  }

  /// Saved tabs fit for `sessionID`'s group: its own tabs, browser and new-tab pages, with its
  /// primary chat (added first among the unpinned tabs when missing) and a valid selection.
  /// - Parameters:
  ///   - snapshot: The saved tabs.
  ///   - sessionID: The group's session.
  /// - Returns: The tabs to make the group with.
  nonisolated static func normalized(_ snapshot: TabWindowSnapshot, for sessionID: String)
    -> TabWindowSnapshot
  {
    let fits = { (content: AppTabContent) in
      belongsInGroup(content) && (content.sessionID ?? sessionID) == sessionID
    }
    let chat = AppTabContent.chat(sessionID: sessionID)
    var hasChat = false
    var tabs = snapshot.tabs.filter { tab in
      guard fits(tab.content) else { return false }
      guard tab.content == chat else { return true }
      defer { hasChat = true }
      return !hasChat
    }
    if !hasChat {
      tabs.insert(AppTab(content: chat), at: tabs.firstIndex { !$0.isPinned } ?? tabs.count)
    }
    let selected = snapshot.selectedID.flatMap { id in tabs.first { $0.id == id }?.id }
    return TabWindowSnapshot(
      tabs: tabs, selectedID: selected ?? tabs.first { $0.content == chat }?.id,
      closed: snapshot.closed.filter { fits($0.content) && !$0.content.isPrimaryChat },
      split: snapshot.split)
  }

  /// Gives browser tabs whose page another window shows a new page id, restored from the saved
  /// state, so one page is never in two windows.
  nonisolated static func reassigningPages(
    _ snapshot: TabWindowSnapshot, inUse: (UUID) -> Bool
  ) -> TabWindowSnapshot {
    var snapshot = snapshot
    for index in snapshot.tabs.indices {
      if case .browser(let pageID) = snapshot.tabs[index].content, inUse(pageID) {
        snapshot.tabs[index].content = .browser(browserID: UUID())
      }
    }
    return snapshot
  }

  /// Whether the group holds just its primary chat, selected, with nothing to reopen: what a
  /// session shows by default, so there is nothing worth saving.
  nonisolated static func isDefault(_ snapshot: TabWindowSnapshot) -> Bool {
    snapshot.tabs.count == 1 && snapshot.tabs[0].content.isPrimaryChat
      && !snapshot.tabs[0].isPinned && snapshot.closed.isEmpty && snapshot.split == nil
  }
}
