import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentStores
import SwiftUI

/// Binds a window's tabs to the connected server: restores the saved tabs (or adopts torn-off
/// ones), registers them for saving, closes browser pages with their tabs, and keeps the
/// sessions the built tabs show open.
struct TabRestoration: ViewModifier {
  let session: ServerSession
  let context: TabWindowContext
  /// Applies the host's selection once the tabs are in place.
  let restored: @MainActor () -> Void

  @State private var boundServer: String?
  @State private var adopted = false

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
    let remoteBrowsers = session.remoteBrowsers
    tabs.willClose = { tab in
      Self.closeRemoteTab(
        Self.closePage(of: tab, in: browser, persistence: context.persistence),
        in: remoteBrowsers, persistence: context.persistence)
    }
    browser?.attach(window: window, tabs: tabs)
    if let persistence = context.persistence {
      if let old = boundServer {
        persistence.unregister(window: window, server: old, keepRecord: true)
      }
      if !adopted, !context.adopting.isEmpty {
        tabs.restore(TabWindowSnapshot())
        tabs.adopt(context.adopting)
      } else if let saved = persistence.claim(window: window, server: server) {
        tabs.restore(saved)
      } else if boundServer != nil {
        tabs.restore(TabWindowSnapshot())
      }
      let session = session
      persistence.register(window: window, server: server) {
        try Self.snapshot(tabs, session: session, browser: browser)
      }
      tabs.onChange = { persistence.scheduleSave(server: server) }
    } else if !adopted, !context.adopting.isEmpty {
      tabs.adopt(context.adopting)
    }
    adopted = true
    boundServer = server
    restored()
  }

  /// The tabs to save, with fresh titles and browser states.
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
