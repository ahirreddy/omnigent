import Foundation
import OSLog
import OmnigentAppBrowser
import OmnigentAppUI
import OmnigentBrowser
import OmnigentUIComponents
import Testing

/// The browser host both apps share: pages keyed by tab, the window's ``TabStore`` as the only
/// closed-tabs stack, and pages a page opens landing in the opener's window.
@MainActor
struct BrowserTabHostTests {
  /// A host over an in-memory browser with the system engine, the only engine on iOS.
  private struct Fixture {
    let environment: BrowserEnvironment
    let host: BrowserTabHost
    let suite = "BrowserTabHostTests.\(UUID().uuidString)"

    init() throws {
      let defaults = try #require(UserDefaults(suiteName: suite))
      let provider = DefaultBrowserEngineProvider()
      environment = BrowserEnvironment(
        directory: nil, provider: provider,
        preferences: BrowserPreferences(defaults: defaults, provider: provider),
        defaults: defaults)
      host = BrowserTabHost(
        environment: environment, agent: nil,
        logger: Logger(subsystem: "tests", category: "tabs"))
    }

    /// A window showing `session`, whose closed browser tabs keep the page's final state, as
    /// the app's. Returns the window and the session's tabs.
    func window(session: String = "s") -> (groups: SessionTabGroups, tabs: TabStore) {
      let groups = SessionTabGroups()
      let host = host
      groups.willClose = { tab in
        guard case .browser(let id) = tab.content else { return tab }
        var closed = tab
        do {
          closed.browserState = try host.close(id)
        } catch {
          Issue.record("closing the page failed: \(error)")
        }
        return closed
      }
      host.attach(window: UUID(), tabs: groups)
      groups.show(.session(session))
      return (groups, groups.group(session))
    }

    func removeDefaults() {
      UserDefaults().removePersistentDomain(forName: suite)
    }
  }

  @Test func closedPagesLiveOnlyInTheTabStore() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let host = fixture.host
    let environment = fixture.environment
    let tabs = fixture.window().tabs

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

  @Test func aNewPageReportsItsAddressAndSavesItsState() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let host = fixture.host
    let page = host.makePage(url: URL(string: "https://example.com/start"))

    let status = try #require(host.status(of: page.id))
    #expect(status.url?.absoluteString == "https://example.com/start")
    #expect(!status.hasError)
    // One profile: the strip shows no profile dot.
    #expect(status.profileColor == nil)
    let state = try #require(page.state)
    let decoded = try JSONDecoder().decode(BrowserTabRestoreState.self, from: state)
    #expect(decoded.url?.host() == "example.com")
    #expect(try host.snapshot(of: page.id) != nil)
    #expect(host.page(page.id) != nil)
  }

  @Test func unknownPagesHaveNoStatusAndCloseToNothing() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let unknown = UUID()
    #expect(fixture.host.status(of: unknown) == nil)
    #expect(try fixture.host.snapshot(of: unknown) == nil)
    #expect(try fixture.host.close(unknown) == nil)
    // No agent browser here: agent tabs show their placeholder.
    #expect(fixture.host.agentContent(for: "session") == nil)
  }

  @Test func pagesOpenedByAPageJoinTheOpenersWindow() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let host = fixture.host
    let first = fixture.window(session: "one").tabs
    let second = fixture.window(session: "two").tabs
    let page = host.makePage(url: URL(string: "https://example.com/a"))
    let openerTab = second.open(.browser(browserID: page.id), browserState: page.state)
    second.open(.newTab)
    let opener = try #require(host.page(page.id))

    let popup = fixture.environment.openTab(
      url: URL(string: "https://example.com/b"), profileID: opener.profileID, opener: opener)
    #expect(first.tabs.count == 1, "the other window keeps just its chat")
    let adopted = try #require(second.selected)
    #expect(adopted.content == .browser(browserID: popup.id))
    #expect(adopted.browserState != nil)
    #expect(host.status(of: popup.id)?.url?.path() == "/b")

    // A background tab joins without taking the selection.
    second.select(openerTab.id)
    let background = fixture.environment.openTab(
      url: URL(string: "https://example.com/c"), profileID: opener.profileID, opener: opener,
      disposition: .backgroundTab)
    #expect(second.selectedID == openerTab.id)
    #expect(second.tabs.contains { $0.content == .browser(browserID: background.id) })
  }

  @Test func switchToTabAndWindowCloseActOnTheTab() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let host = fixture.host
    let tabs = fixture.window().tabs
    let page = host.makePage(url: URL(string: "https://example.com/a"))
    let tab = tabs.open(.browser(browserID: page.id), browserState: page.state)
    tabs.open(.newTab)
    let model = try #require(host.page(page.id))

    fixture.environment.onSwitchToTab?(model.id)
    #expect(tabs.selectedID == tab.id)

    // The page called `window.close()`: its tab closes, and the page with it.
    fixture.environment.onCloseTab?(model)
    #expect(!tabs.tabs.contains { $0.id == tab.id })
    #expect(host.page(page.id) == nil)
  }

  @Test func closingAWindowClosesItsPages() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let host = fixture.host
    let groups = SessionTabGroups()
    let window = UUID()
    host.attach(window: window, tabs: groups)
    let page = host.makePage(url: URL(string: "https://example.com/a"))
    groups.group("s").open(.browser(browserID: page.id), browserState: page.state)
    #expect(host.isPageShown(page.id, outside: UUID()))
    #expect(!host.isPageShown(page.id, outside: window))

    host.windowClosed(window)
    #expect(host.page(page.id) == nil)
    #expect(fixture.environment.recentlyClosed.states.isEmpty)
  }
}
