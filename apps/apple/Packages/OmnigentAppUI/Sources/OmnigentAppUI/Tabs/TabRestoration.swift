import Foundation
import OSLog
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// Binds a window's session tabs to the connected server: restores the window's page, reads
/// each session's saved tabs when it first shows, registers them for saving, closes browser
/// pages with their tabs, and keeps the recently shown sessions open.
struct TabRestoration: ViewModifier {
  let session: ServerSession
  let context: TabWindowContext
  /// Applies the window's saved page (unless the host already chose one) once bound.
  let restored: @MainActor (SidebarDestination?) -> Void

  @State private var boundServer: String?

  private var server: String? { session.connection.connectedServer?.baseUrl }

  func body(content: Content) -> some View {
    content
      .onChange(of: server, initial: true) { bind() }
      .onChange(of: session.tabs.liveSessionIDs, initial: true) { _, wanted in
        session.keepOpen(wanted)
      }
  }

  private func bind() {
    guard let server, server != boundServer else { return }
    let tabs = session.tabs
    let browser = context.browser
    let window = context.window
    let persistence = context.persistence
    let remoteBrowsers = session.remoteBrowsers
    if boundServer != nil {
      // Another server's sessions: their tabs leave with it.
      tabs.onChange = nil
      if let old = boundServer {
        persistence?.unregister(window: window, server: old, keepRecord: true)
      }
      tabs.reset()
    }
    tabs.willClose = { tab in
      Self.closeRemoteTab(
        Self.closePage(of: tab, in: browser, persistence: persistence),
        in: remoteBrowsers, persistence: persistence)
    }
    tabs.pageInUse = { [weak browser] id in browser?.isPageShown(id, outside: window) ?? false }
    browser?.attach(window: window, tabs: tabs)
    var saved: SidebarDestination?
    if let persistence {
      saved = persistence.claim(window: window, server: server)
      tabs.loadSaved = { persistence.savedTabs(session: $0, server: server, for: window) }
      tabs.onRemove = { persistence.removeSessions($0, server: server) }
      let session = session
      persistence.register(
        window: window, server: server,
        snapshot: { try Self.state(tabs, session: session, browser: browser) },
        group: { sessionID in
          Self.groupState(sessionID, of: tabs, session: session, browser: browser)
        })
      tabs.onChange = { _ in persistence.scheduleSave(server: server) }
    }
    boundServer = server
    restored(saved)
  }

  /// The window's tabs to save: its page and the groups changed since they were made, with
  /// fresh titles and browser states.
  static func state(
    _ tabs: SessionTabGroups, session: ServerSession, browser: (any BrowserTabHosting)?
  ) throws -> TabWindowState {
    var groups: [String: TabGroupState] = [:]
    for (sessionID, group) in tabs.groups where group.changedAt != nil {
      groups[sessionID] = TabGroupState(
        snapshot: try snapshot(group, session: session, browser: browser),
        changedAt: group.changedAt)
    }
    return TabWindowState(page: tabs.page, groups: groups)
  }

  /// One session's tabs for another window that shows the session for the first time. A page
  /// whose state does not encode keeps its last saved state.
  static func groupState(
    _ sessionID: String, of tabs: SessionTabGroups, session: ServerSession,
    browser: (any BrowserTabHosting)?
  ) -> TabGroupState? {
    guard let group = tabs.groups[sessionID] else { return nil }
    do {
      return TabGroupState(
        snapshot: try snapshot(group, session: session, browser: browser),
        changedAt: group.changedAt)
    } catch {
      Logger(subsystem: "ai.omnigent.app", category: "tabs").error(
        "A session's pages did not encode: \(String(describing: error), privacy: .public)")
      return TabGroupState(snapshot: group.snapshot, changedAt: group.changedAt)
    }
  }

  /// A group's tabs to save, with fresh titles and browser states.
  static func snapshot(
    _ tabs: TabStore, session: ServerSession, browser: (any BrowserTabHosting)?
  ) throws -> TabWindowSnapshot {
    var snapshot = tabs.snapshot
    snapshot.tabs = try snapshot.tabs.map { tab in
      var tab = tab
      if let title = TabAdapter.cachedTitle(tab, session: session, browser: browser) {
        tab.title = title
      }
      if case .browser(let id) = tab.content, let state = try browser?.snapshot(of: id) {
        tab.browserState = state
      }
      if case .remoteBrowser(let sessionID, let tabID) = tab.content,
        let store = session.remoteBrowsers?.existingStore(sessionID: sessionID, tabID: tabID)
      {
        tab.browserState = try RemoteBrowserTabRecord(
          url: store.lastURL, profile: store.profile
        ).encoded()
      }
      return tab
    }
    return snapshot
  }

  /// Closes the remote tab behind a closing remote browser tab, keeping its last URL so Reopen
  /// Closed Tab can offer to open it again.
  static func closeRemoteTab(
    _ tab: AppTab, in remoteBrowsers: RemoteBrowserTabs?, persistence: TabPersistence?
  ) -> AppTab {
    guard case .remoteBrowser(let sessionID, let tabID) = tab.content, let remoteBrowsers else {
      return tab
    }
    var tab = tab
    if let store = remoteBrowsers.existingStore(sessionID: sessionID, tabID: tabID) {
      do {
        tab.browserState = try RemoteBrowserTabRecord(
          url: store.lastURL, profile: store.profile
        ).encoded()
      } catch {
        persistence?.reportIssue("A closed remote tab's address could not be kept: \(error)")
      }
    }
    Task {
      do {
        try await remoteBrowsers.close(sessionID: sessionID, tabID: tabID)
      } catch {
        persistence?.reportIssue("The remote browser tab could not be closed: \(error)")
      }
    }
    return tab
  }

  /// Closes a closing browser tab's page and keeps its final state for Reopen Closed Tab.
  static func closePage(
    of tab: AppTab, in browser: (any BrowserTabHosting)?, persistence: TabPersistence?
  ) -> AppTab {
    guard case .browser(let id) = tab.content, let browser else { return tab }
    var tab = tab
    do {
      if let state = try browser.close(id) { tab.browserState = state }
    } catch {
      // The page is closed either way; Reopen Closed Tab falls back to the last saved state.
      persistence?.reportIssue("A closed page's history could not be kept: \(error)")
    }
    return tab
  }
}
