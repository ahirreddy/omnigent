import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

// MARK: Tab pages

extension ConnectedServerView {
  /// The new-session page, or beside a source session its Add nested agent composer, which opens
  /// a created session whose setup didn't finish under `notify`'s notice.
  @ViewBuilder func newSessionPage(
    nestedBeside destination: SidebarDestination?, notify: @escaping @MainActor (String) -> Void
  ) -> some View {
    let selection = selectionBinding
    let open: @MainActor (String) -> Void = { selection.wrappedValue = .session($0) }
    if case .nestedSession(let sourceID) = destination {
      // A kept composer comes back as it was left.
      NewSessionContainer(
        connection: connection, form: session.nestedComposerDrafts.form(for: sourceID),
        nestedSourceID: sourceID, open: open,
        openWithNotice: { sessionID, notice in
          open(sessionID)
          notify(notice)
        },
        continueInNewSession: { selection.wrappedValue = .newSession },
        nestedDrafts: session.nestedComposerDrafts
      )
      .id(sourceID)
    } else {
      NewSessionContainer(
        connection: connection, open: open,
        openWorkflow: { [connection] id in
          connection.workflows?.requestedWorkflowID = id
          selection.wrappedValue = .workflows
        })
    }
  }

  /// Opens the Add nested agent composer beside `sourceID`, with its family, folder and section
  /// open in the sidebar so its provisional row shows.
  func addNestedAgent(beside sourceID: String) {
    sidebarModel.collapsedFamilies = SidebarNavigationOrder.reveal(sourceID, in: sidebarState)
    selectionBinding.wrappedValue = .nestedSession(sourceID: sourceID)
  }

  /// Deletes an Add nested agent composer's draft: its row, text, choices and files. An open
  /// composer for it gives way to its source session.
  func deleteNestedDraft(rowID: String) {
    guard let creation = connection.creationStore,
      let draft = creation.nestedDrafts.first(where: { $0.id == rowID }),
      draft.createdSessionID == nil
    else { return }
    let sourceID = draft.source.id
    if selectionBinding.wrappedValue == .nestedSession(sourceID: sourceID) {
      selectionBinding.wrappedValue = .session(sourceID)
    }
    creation.closeNestedDraft(key: draft.key)
    creation.composerDrafts[sourceID] = nil
    session.nestedComposerDrafts.discard(sourceID)
  }

  /// The strip's tabs, read when the titlebar asks for them; a session-less page has no strip.
  /// They are the last shown session's, which a page leaves as they were: going to a page then
  /// takes the strip away without rendering it first.
  func strip(of tabs: WindowTabs) -> ShellTabs {
    ShellTabs(
      isShown: { tabs.groups.currentSessionID != nil },
      content: {
        guard let store = tabs.groups.lastShown else { return (TabsState(), TabActions()) }
        return (tabs.state(store), renamable(tabs.actions(store)))
      })
  }

  /// A chat tab's menu renames its session, as the session menu and Option-Command-R do.
  func renamable(_ actions: TabActions) -> TabActions {
    var actions = actions
    actions.renameSession = renameSessionOfTab
    return actions
  }

  /// Asks for a new title for the session of a chat tab, by the tab's id.
  var renameSessionOfTab: @MainActor (String) -> Void {
    let (model, tabs, list) = (sidebarModel, session.tabs, connection.sessionList)
    return { model.askToRename(tabID: $0, tabs: tabs, list: list) }
  }

  /// The New Tab page; the window reads what it offers (``NewTabOptionsLoading``).
  func newTabPage(_ tab: AppTab, routes: WindowTabs) -> some View {
    NewTabPage(state: routes.newTabState, actions: routes.newTabActions(replacing: tab.id))
  }

  /// A session's remote browser tab. On iPhone it hides the navigation bar (Safari's layout),
  /// so it offers the session list and the tab overview itself.
  func remoteBrowser(
    _ tab: AppTab, sessionID: String, tabID: String, routes: WindowTabs
  ) -> some View {
    RemoteBrowserTabContainer(
      session: session, tab: tab, sessionID: sessionID, tabID: tabID,
      reopen: reopenRemoteBrowser(tab, sessionID: sessionID, routes: routes),
      showSessions: { selectionBinding.wrappedValue = nil },
      tabsButton: { tabsButton(routes) })
  }

  /// A remote tab that ended opens again at a URL, in its place.
  func reopenRemoteBrowser(
    _ tab: AppTab, sessionID: String, routes: WindowTabs
  ) -> @MainActor (String, RemoteBrowserTabRecord) -> Void {
    { url, record in
      Task {
        await routes.openRemoteBrowser(
          in: sessionID, profile: record.profile, url: url, replacing: tab.id)
      }
    }
  }

  /// The tab-count button for a page that hides the navigation bar (iPhone).
  func tabsButton(_ routes: WindowTabs) -> TabSwitcherButton {
    let strip = routes.strip
    return TabSwitcherButton(
      state: strip?.state ?? TabsState(), actions: strip?.actions ?? TabActions())
  }

  /// The tabs built in the detail: the shown tab (both panes' tabs of a split) with the
  /// recently shown chats of the live sessions, and a session-less page over them. Compact
  /// keeps only what shows, in the same container, so a size-class change (rotating a large
  /// iPhone) does not rebuild it.
  func keptAlive(page: AppTab?, isCompact: Bool) -> [AppTab] {
    let tabs = session.tabs
    // A board's quick view builds its session's chat itself.
    let kept = tabs.keptAlive().filter { tab in
      tabs.quickViewSessionID.map { tab.content.conversationID != $0 } ?? true
    }
    guard isCompact else { return kept + (page.map { [$0] } ?? []) }
    return (tabs.selected ?? page).map { [$0] } ?? []
  }

  /// A session-less page as a tab of the kept-alive stack, under one stable id.
  static func pageTab(_ destination: SidebarDestination) -> AppTab {
    AppTab(id: "page", content: AppTabContent(destination))
  }
}

/// Reads the shown session's remote browser profiles for the New Tab page and the + menu each
/// time a session shows; its declared terminals load when it opens (``ServerSession/open(_:)``).
struct NewTabOptionsLoading: ViewModifier {
  let session: ServerSession

  func body(content: Content) -> some View {
    let sessionID = session.tabs.currentSessionID
    return content.task(id: sessionID) { await session.loadRemoteBrowserProfiles(sessionID) }
  }
}
