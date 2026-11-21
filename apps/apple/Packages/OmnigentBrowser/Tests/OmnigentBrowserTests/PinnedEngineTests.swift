import Foundation
import Testing

@testable import OmnigentBrowser

/// A tab pinned to an engine keeps it whatever the preference.
@MainActor
struct PinnedEngineTests {
  /// An agent's tab needs Chromium's DevTools, so it keeps Chromium under a WebKit preference
  /// until the user picks an engine for it.
  @Test func aPinnedEngineOutranksThePreferenceUntilTheUserSwitches() throws {
    let provider = FakeProvider()
    let preferences = BrowserPreferences(defaults: try isolatedDefaults(), defaultEngine: .system)
    let controller = BrowserController(
      profile: .server("a"), preferences: preferences, provider: provider, initialURL: nil,
      pinnedEngine: .chromium)
    controller.activate()
    controller.retry()
    #expect(controller.tab?.engineKind == .chromium)
    #expect(provider.requests.allSatisfy { $0 == .chromium })

    controller.switchEngine(to: .system)
    #expect(controller.pinnedEngine == nil)
    #expect(controller.tab?.engineKind == .system)
  }

  @Test func restoreStateKeepsThePinnedEngine() throws {
    let state = BrowserTabRestoreState(profileID: UUID(), url: nil, engine: .chromium)
    let decoded = try JSONDecoder().decode(
      BrowserTabRestoreState.self, from: try JSONEncoder().encode(state))
    #expect(decoded.engine == .chromium)
    let legacy = Data(#"{"version":1,"id":"\#(UUID())","profileID":"\#(UUID())"}"#.utf8)
    #expect(try JSONDecoder().decode(BrowserTabRestoreState.self, from: legacy).engine == nil)
  }

  @Test func aReplacedEngineTabStaysHeldForTheAgent() throws {
    let (environment, provider) = try makeEnvironment()
    let model = environment.makeTab(url: try testURL("https://agent.example/"))
    model.activate()
    model.setAgentControl(.idle)
    model.controller.retry()
    let tabs = try #require(provider.engines[.chromium]?.tabs)
    #expect(tabs.count == 2)
    let replacement = try #require(tabs.last?.agentInput as? RecordingAgentInput)
    #expect(replacement.holds == [true])
    model.setAgentControl(nil)
    #expect(replacement.holds == [true, false])
  }
}
