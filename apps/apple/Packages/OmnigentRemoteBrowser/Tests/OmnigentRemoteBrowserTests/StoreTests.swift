import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

@MainActor
@Suite("Remote browser store over the fixture host")
struct StoreTests {
  /// Polls until `condition` holds or two seconds pass.
  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test func attachesPlaysVideoAndNavigates() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(5))
    host.addTab(id: "btab_1", url: "https://example.com/")
    let store = RemoteBrowserStore(sessionID: "conv_a", tabID: "btab_1")
    let renderer = RemoteVideoRenderer()
    store.renderer = renderer
    store.attach(using: host, mode: .control, hostID: nil)
    #expect(try await eventually { store.snapshot.connection == .attached(mode: .control) })
    #expect(store.snapshot.viewport == RemoteViewport(width: 1280, height: 800, dpr: 1))
    #expect(try await eventually { renderer.framesEnqueued > 2 })
    #expect(store.canSendInput)
    #expect(store.submitAddress("omnigent.ai/docs"))
    #expect(try await eventually { store.navigation.url == "https://omnigent.ai/docs" })
    #expect(store.navigation.canGoBack)
    #expect(try await eventually { !store.navigation.loading })
    #expect(!store.submitAddress("   "))
    store.releaseControl()
    #expect(try await eventually { store.snapshot.control?.owner == .agent })
    #expect(!store.canSendInput)
    store.detach()
    #expect(try await eventually { store.snapshot.connection == .stopped })
  }

  @Test func aURLWithSmallSwitchesToTheSmallStream() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(5))
    host.addTab(id: "btab_1", url: "https://example.com/")
    let store = RemoteBrowserStore(sessionID: "conv_a", tabID: "btab_1")
    let renderer = RemoteVideoRenderer()
    store.renderer = renderer
    store.attach(using: host, mode: .control, hostID: nil)
    #expect(try await eventually { renderer.videoSize == CGSize(width: 1280, height: 800) })
    store.submitAddress("https://example.com/small")
    #expect(try await eventually { renderer.videoSize == CGSize(width: 640, height: 400) })
    #expect(try await eventually { store.snapshot.viewport?.width == 640 })
    store.detach()
  }

  @Test func aTabTheHostDoesNotKnowEnds() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(5))
    let store = RemoteBrowserStore(
      sessionID: "conv_a", tabID: "btab_gone", lastURL: "https://github.com/login")
    store.attach(using: host, mode: .control, hostID: nil)
    #expect(try await eventually { store.isEnded })
    #expect(store.lastURL == "https://github.com/login")
  }

  @Test func theRegistryCreatesKeepsAndClosesTabs() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(5))
    let tabs = RemoteBrowserTabs(connector: host)
    await tabs.loadProfiles(sessionID: "conv_a")
    #expect(tabs.profiles["conv_a"]?.map(\.name) == ["default", "work"])
    let opened = try #require(
      await tabs.open(sessionID: "conv_a", url: "https://example.com/", profile: "work"))
    #expect(opened.record == RemoteBrowserTabRecord(url: "https://example.com/", profile: "work"))
    let store = tabs.store(sessionID: "conv_a", tabID: opened.tab.id, record: opened.record)
    #expect(tabs.store(sessionID: "conv_a", tabID: opened.tab.id, record: nil) === store)
    #expect(store.profile == "work")
    tabs.attach(store, mode: .control, hostID: nil)
    #expect(try await eventually { store.snapshot.connection == .attached(mode: .control) })
    try await tabs.close(sessionID: "conv_a", tabID: opened.tab.id)
    #expect(tabs.existingStore(sessionID: "conv_a", tabID: opened.tab.id) == nil)
    await #expect(throws: FixtureRemoteBrowserError.tabNotFound("btab_missing")) {
      try await tabs.close(sessionID: "conv_a", tabID: "btab_missing")
    }
  }

  @Test func recordsRoundTrip() throws {
    let record = RemoteBrowserTabRecord(url: "https://example.com/", profile: "default")
    #expect(try RemoteBrowserTabRecord(decoding: record.encoded()) == record)
  }
}
