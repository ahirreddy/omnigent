import OmnigentRemoteBrowser
import OmnigentUIComponents
import SwiftUI

// MARK: Tab pages

extension ConnectedServerView {
  /// The New Tab page, loading what its recent sessions offer (browser profiles, terminals).
  func newTabPage(_ tab: AppTab, routes: WindowTabs) -> some View {
    NewTabPage(state: routes.newTabState, actions: routes.newTabActions(replacing: tab.id))
      .task(id: routes.newTabState.recentSessions.map(\.id)) {
        let recent = routes.newTabState.recentSessions.map(\.id)
        async let profiles: Void = session.loadRemoteBrowserProfiles(recent.first)
        await session.loadDeclaredTerminalNames(recent)
        await profiles
      }
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

  /// The tabs built in the detail: the shown tab with the recently shown chats of the live
  /// sessions, and a session-less page over them. Compact keeps only what shows, in the same
  /// container, so a size-class change (rotating a large iPhone) does not rebuild it.
  func keptAlive(page: AppTab?, isCompact: Bool) -> [AppTab] {
    let tabs = session.tabs
    guard isCompact else { return tabs.keptAlive() + (page.map { [$0] } ?? []) }
    return (tabs.selected ?? page).map { [$0] } ?? []
  }

  /// A session-less page as a tab of the kept-alive stack, under one stable id.
  static func pageTab(_ destination: SidebarDestination) -> AppTab {
    AppTab(id: "page", content: AppTabContent(destination))
  }

  /// The tab a pane shows: the selected tab when the session is not split.
  func paneTab(_ pane: TabPane, in tabs: TabStore) -> AppTab? {
    guard let split = tabs.splitState else { return tabs.selected }
    return split.activeID(pane).flatMap(tabs.tab)
  }
}
