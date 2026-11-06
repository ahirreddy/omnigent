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
      reopen: { url, record in
        Task {
          await routes.openRemoteBrowser(
            in: sessionID, profile: record.profile, url: url, replacing: tab.id)
        }
      },
      showSessions: { selectionBinding.wrappedValue = nil },
      tabsButton: { TabSwitcherButton(state: routes.state, actions: routes.actions) })
  }
}
