import Foundation
import OSLog
import OmnigentAppUI
import OmnigentBrowser
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// The window's ``TabStore`` is the only closed-tabs stack: a browser tab closed from the strip
/// is remembered there, never also in the browser's own recently-closed list, so reopening it
/// cannot bring the page back twice.
@MainActor
struct BrowserTabHostTests {
  @Test func closedPagesLiveOnlyInTheTabStore() throws {
    let suite = "BrowserTabHostTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = AppEdition.makeBrowserProvider()
    let environment = BrowserEnvironment(
      directory: nil, provider: provider,
      preferences: BrowserPreferences(defaults: defaults, provider: provider), defaults: defaults)
    let host = BrowserTabHost(
      environment: environment, agent: nil, logger: Logger(subsystem: "tests", category: "tabs"))
    let tabs = TabStore()
    tabs.willClose = { tab in
      guard case .browser(let id) = tab.content else { return tab }
      var closed = tab
      do {
        closed.browserState = try host.close(id)
      } catch {
        Issue.record("closing the page failed: \(error)")
      }
      return closed
    }
    host.attach(window: UUID(), tabs: tabs)

    let page = host.makePage(url: URL(string: "https://example.com/docs"))
    let tab = tabs.open(.browser(browserID: page.id), browserState: page.state)
    tabs.close(tab.id)
    #expect(tabs.closed.map(\.id) == [tab.id])
    #expect(tabs.closed.first?.browserState != nil)
    #expect(environment.recentlyClosed.states.isEmpty)

    // Reopen through the tab store, build the page again, and close it a second time.
    let reopened = try #require(tabs.reopenClosed())
    #expect(reopened.content == .browser(browserID: page.id))
    #expect(tabs.closed.isEmpty)
    _ = host.content(for: page.id, restoring: reopened.browserState) {}
    #expect(host.status(of: page.id)?.url?.host() == "example.com")
    tabs.close(reopened.id)
    #expect(tabs.closed.count == 1)
    #expect(environment.recentlyClosed.states.isEmpty)
    #expect(environment.reopenClosedTab() == nil)
  }
}
