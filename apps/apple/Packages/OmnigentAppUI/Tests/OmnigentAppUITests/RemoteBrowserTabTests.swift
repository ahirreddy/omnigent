import Foundation
import OmnigentRemoteBrowser
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@Suite("Remote browser tabs")
struct RemoteBrowserTabTests {
  @Test("A remote tab belongs to its session, focuses an existing tab, and round-trips")
  func content() throws {
    let content = AppTabContent.remoteBrowser(sessionID: "conv_a", tabID: "btab_1")
    #expect(content.kind == .remoteBrowser)
    #expect(content.sessionID == "conv_a")
    #expect(content.focusesExisting)
    #expect(content.destination == nil)
    let record = RemoteBrowserTabRecord(url: "https://github.com/login", profile: "work")
    let tab = AppTab(content: content, title: "Sign in", browserState: try record.encoded())
    let decoded = try JSONDecoder().decode(AppTab.self, from: JSONEncoder().encode(tab))
    #expect(decoded == tab)
    #expect(RemoteBrowserTabContainer.record(decoded) == record)
  }

  @Test("A tab without a readable record shows no last page")
  func unreadableRecord() {
    let tab = AppTab(
      content: .remoteBrowser(sessionID: "conv_a", tabID: "btab_1"), browserState: Data("{}".utf8))
    #expect(RemoteBrowserTabContainer.record(tab) == nil)
    #expect(RemoteBrowserTabContainer.record(AppTab(content: .newTab)) == nil)
  }

  @Test("Remote tabs are off by default; a default turns on the fixture host")
  func availability() throws {
    let name = "RemoteBrowserTabTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(RemoteBrowserAvailability.connector(core: nil, defaults: defaults) == nil)
    defaults.set(true, forKey: RemoteBrowserAvailability.enabledDefault)
    #expect(RemoteBrowserAvailability.connector(core: nil, defaults: defaults) == nil)
    defaults.set(true, forKey: RemoteBrowserAvailability.fixtureDefault)
    let connector = RemoteBrowserAvailability.connector(core: nil, defaults: defaults)
    #expect(connector === FixtureRemoteBrowser.shared)
  }
}
