import Foundation
import OmnigentAppUI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppBrowser
@testable import OmnigentBrowser

/// The browser host's directory for an agent's DevTools proxy: the agent's state on a page's
/// badge and strip, the user's Take Over and Stop, and pages outside the session.
@MainActor
struct BrowserTabHostDevToolsTests {
  typealias Fixture = BrowserTabHostTests.Fixture

  /// Counts the agent strip's Stop.
  @MainActor
  final class Stops {
    var count = 0
  }

  /// A page the agent's DevTools directory knows by target, in session `s`'s tabs.
  private func agentPage(_ fixture: Fixture, tabs: TabStore) -> (id: UUID, tab: AppTab) {
    let page = fixture.host.makePage(url: URL(string: "https://example.com/inbox"))
    let tab = tabs.open(.browser(browserID: page.id), select: false, browserState: page.state)
    _ = fixture.host.content(for: page.id, restoring: page.state, navigation: nil) {}
    fixture.host.devToolsTargets[page.id] = "TARGET-1"
    return (page.id, tab)
  }

  @Test func theAgentsStateBadgesThePageAndNeverOverridesTheUser() async throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let host = fixture.host
    let (id, _) = agentPage(fixture, tabs: fixture.window().tabs)
    let stops = Stops()

    try host.setDevToolsAgentState(
      sessionID: "s", targetID: "TARGET-1", state: "active", stopTurn: { stops.count += 1 })
    #expect(host.status(of: id)?.agentControl == .active)
    #expect(await host.devToolsTabs(sessionID: "s").map(\.owner) == ["agent"])

    let model = try #require(host.page(id))
    model.performAgentControl(.takeOver)
    try host.setDevToolsAgentState(
      sessionID: "s", targetID: "TARGET-1", state: "active", stopTurn: { stops.count += 1 })
    #expect(host.status(of: id)?.agentControl == .user)
    #expect(await host.devToolsTabs(sessionID: "s").map(\.owner) == ["user"])

    model.performAgentControl(.handBack)
    #expect(model.agentControl == .idle)
    model.performAgentControl(.stop)
    #expect(model.agentControl == .user && stops.count == 1)

    try host.setDevToolsAgentState(
      sessionID: "s", targetID: "TARGET-1", state: "released", stopTurn: {})
    #expect(host.status(of: id)?.agentControl == nil)
  }

  /// The agent's directory requests arrive on the session's stream, so a session whose tab the
  /// agent holds stays open after the window moves on, until the agent lets go.
  @Test func aSessionStaysOpenWhileTheAgentHoldsItsTab() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let window = fixture.window()
    _ = agentPage(fixture, tabs: window.tabs)
    window.groups.liveLimit = 1
    window.groups.show(.session("other"))
    #expect(!window.groups.liveSessionIDs.contains("s"))

    try fixture.host.setDevToolsAgentState(
      sessionID: "s", targetID: "TARGET-1", state: "idle", stopTurn: {})
    #expect(window.groups.liveSessionIDs.contains("s"))

    try fixture.host.setDevToolsAgentState(
      sessionID: "s", targetID: "TARGET-1", state: "released", stopTurn: {})
    #expect(!window.groups.liveSessionIDs.contains("s"))
  }

  /// Only Chromium has DevTools, so an agent's page uses it under a WebKit preference too.
  @Test func anAgentsPageKeepsChromiumWhateverThePreference() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    fixture.environment.preferences.engine = .system
    let page = fixture.host.makePage(url: nil, engine: .chromium)
    #expect(fixture.host.page(page.id)?.controller.wantedEngine == .chromium)
    let plain = fixture.host.makePage(url: nil)
    #expect(fixture.host.page(plain.id)?.controller.wantedEngine == .system)
  }

  @Test func anotherSessionsPagesAreUnknownToTheAgent() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    _ = agentPage(fixture, tabs: fixture.window().tabs)

    #expect(throws: BrowserError.tabClosed) {
      try fixture.host.setDevToolsAgentState(
        sessionID: "other", targetID: "TARGET-1", state: "active", stopTurn: {})
    }
    #expect(throws: BrowserError.tabClosed) {
      try fixture.host.closeDevToolsTab(sessionID: "other", targetID: "TARGET-1")
    }
  }

  @Test func theAgentClosesItsTabThroughTheSessionsTabSet() throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let tabs = fixture.window().tabs
    let (_, tab) = agentPage(fixture, tabs: tabs)

    try fixture.host.closeDevToolsTab(sessionID: "s", targetID: "TARGET-1")

    #expect(!tabs.tabs.contains { $0.id == tab.id })
    #expect(tabs.closed.map(\.id) == [tab.id])
  }

  @Test func anEngineWithoutDevToolsLeavesNoAgentTabBehind() async throws {
    let fixture = try Fixture()
    defer { fixture.removeDefaults() }
    let tabs = fixture.window().tabs
    let before = tabs.tabs.map(\.id)

    await #expect(throws: BrowserError.self) {
      try await fixture.host.openDevToolsTab(sessionID: "s", url: nil, stopTurn: {})
    }
    #expect(tabs.tabs.map(\.id) == before)
  }
}
