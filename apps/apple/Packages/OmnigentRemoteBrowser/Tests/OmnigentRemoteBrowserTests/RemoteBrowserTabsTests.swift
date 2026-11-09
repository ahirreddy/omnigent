import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentServices
import OmnigentTestSupport
import OmnigentViewTesting
import Synchronization
import Testing

@testable import OmnigentRemoteBrowser

/// A connector that answers as a test says, for what a server can do to tab creation.
nonisolated final class ScriptedConnector: RemoteBrowserConnecting {
  let driver = RecordingBrowserDriver()
  private let fixture = FixtureRemoteBrowser(latency: .zero)
  private let failure = Mutex<(any Error & Sendable)?>(nil)
  private let closed = Mutex<[String]>([])

  var closedTabs: [String] { closed.withLock { $0 } }
  func fail(with error: (any Error & Sendable)?) { failure.withLock { $0 = error } }

  private func check() throws {
    if let error = failure.withLock({ $0 }) { throw error }
  }

  func profiles(sessionID: String) throws -> [RemoteBrowserProfile] {
    try check()
    return [RemoteBrowserProfile(name: "work", running: true)]
  }

  func createTab(sessionID: String, url: String?, profile: String?) async throws
    -> RemoteBrowserTab
  {
    try check()
    return try await fixture.createTab(sessionID: sessionID, url: url, profile: profile)
  }

  func closeTab(sessionID: String, tabID: String) throws {
    try check()
    closed.withLock { $0.append(tabID) }
  }

  func attach(
    sessionID: String, tabID: String, mode: RemoteBrowserMode, hostID: String?,
    listener: any RemoteBrowserListener
  ) -> any RemoteBrowserDriverProtocol {
    driver
  }
}

private struct PlainFailure: Error, CustomStringConvertible {
  var description: String { "plain failure" }
}

@Suite("The connection's remote tabs")
struct RemoteBrowserTabsTests {
  @Test("a session's profiles are read, and a failed read says why")
  func profiles() async {
    let connector = ScriptedConnector()
    let tabs = RemoteBrowserTabs(connector: connector)
    await tabs.loadProfiles(sessionID: "s")
    #expect(tabs.profiles["s"]?.map(\.name) == ["work"])
    #expect(tabs.lastError == nil)
    connector.fail(with: PlainFailure())
    await tabs.loadProfiles(sessionID: "other")
    #expect(tabs.profiles["other"] == nil)
    #expect(tabs.lastError == "plain failure")
  }

  @Test("opening a tab gives its record; a failure says why and a later success clears it")
  func open() async throws {
    let connector = ScriptedConnector()
    let tabs = RemoteBrowserTabs(connector: connector)
    connector.fail(
      with: CoreError.RemoteBrowser(
        kind: .invalidUrl, message: "That address is not valid", requiresSignIn: false))
    let refused = await tabs.open(sessionID: "s", url: "::", profile: nil)
    #expect(refused == nil)
    #expect(tabs.lastError?.contains("That address is not valid") == true)

    connector.fail(with: PlainFailure())
    let failed = await tabs.open(sessionID: "s", url: nil, profile: nil)
    #expect(failed == nil)
    #expect(tabs.lastError == "plain failure")

    connector.fail(with: nil)
    let opened = try #require(
      await tabs.open(sessionID: "s", url: "https://example.com/", profile: "work"))
    #expect(opened.tab.url == "https://example.com/")
    #expect(opened.record == RemoteBrowserTabRecord(url: "https://example.com/", profile: "work"))
    #expect(tabs.lastError == nil)
  }

  @Test("moving a tab to another window detaches it but keeps the remote tab")
  func detach() {
    let connector = ScriptedConnector()
    let tabs = RemoteBrowserTabs(connector: connector)
    let store = tabs.store(sessionID: "s", tabID: "t", record: nil)
    tabs.attach(store, mode: .control, hostID: nil)
    #expect(tabs.existingStore(sessionID: "s", tabID: "t") === store)
    tabs.detach(sessionID: "s", tabID: "t")
    #expect(tabs.existingStore(sessionID: "s", tabID: "t") == nil)
    #expect(connector.driver.log.contains("stop"))
    #expect(connector.closedTabs.isEmpty)
  }

  @Test("a closed window detaches every tab; closing a tab also closes it on the host")
  func detachAllAndClose() async throws {
    let connector = ScriptedConnector()
    let tabs = RemoteBrowserTabs(connector: connector)
    let first = tabs.store(sessionID: "s", tabID: "a", record: nil)
    let second = tabs.store(sessionID: "s", tabID: "b", record: nil)
    tabs.attach(first, mode: .control, hostID: nil)
    tabs.attach(second, mode: .view, hostID: nil)
    tabs.detachAll()
    #expect(tabs.existingStore(sessionID: "s", tabID: "a") == nil)
    #expect(tabs.existingStore(sessionID: "s", tabID: "b") == nil)
    #expect(connector.driver.log.filter { $0 == "stop" }.count == 2)
    #expect(connector.closedTabs.isEmpty)

    _ = tabs.store(sessionID: "s", tabID: "c", record: nil)
    try await tabs.close(sessionID: "s", tabID: "c")
    #expect(connector.closedTabs == ["c"])
  }
}

@Suite("The server's remote browser calls")
struct CoreConnectorTests {
  /// A core with no server behind it: each call ends in a core error, not a crash.
  private func connector() throws -> CoreRemoteBrowserConnector {
    let http = FakeHttpTransport { _ throws(TransportError) in
      HttpResponse(status: 404, headers: [], body: Data(#"{"detail":"not found"}"#.utf8))
    }
    let core = try ClientCore(
      http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    return CoreRemoteBrowserConnector(core: core)
  }

  @Test("REST calls with no connection fail as core errors")
  func restCalls() async throws {
    let connector = try connector()
    await #expect(throws: CoreError.self) { try await connector.profiles(sessionID: "s") }
    await #expect(throws: CoreError.self) {
      try await connector.createTab(sessionID: "s", url: nil, profile: nil)
    }
    await #expect(throws: CoreError.self) {
      try await connector.closeTab(sessionID: "s", tabID: "t")
    }
  }

  @Test("a connected core's tab calls carry the server's answers")
  func connectedCalls() async throws {
    let resources = "/v1/sessions/s/resources"
    let tab = """
      {"id":"t","type":"browser","session_id":"s","name":"Page","metadata":{"url":"https://a.test/"}}
      """
    let http = FakeHttpTransport(routes: [
      "/.well-known/omnigent.json": .json(ManifestFixtures.localNoAuth),
      "/v1/info": .json(#"{"single_user":true,"accounts_enabled":false}"#),
      "/v1/me": .json(#"{"user_id":"local"}"#),
      "/v1/sessions": .json(#"{"object":"list","data":[],"has_more":false}"#),
      "\(resources)/browser_profiles": .json(#"{"data":[{"name":"work","running":true}]}"#),
      "\(resources)/browsers": .json(tab),
      "\(resources)/browsers/t": .json(#"{"deleted":true,"id":"t"}"#),
    ])
    let core = try ClientCore(
      http: http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TaskScheduler(), secureStore: InMemorySecureStore(),
      entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
    _ = try await core.connect(serverUrl: "http://127.0.0.1:6767", expectedUserId: nil)
    let connector = CoreRemoteBrowserConnector(core: core)
    #expect(try await connector.profiles(sessionID: "s").map(\.name) == ["work"])
    let created = try await connector.createTab(sessionID: "s", url: nil, profile: nil)
    #expect(created.id == "t")
    #expect(created.url == "https://a.test/")
    try await connector.closeTab(sessionID: "s", tabID: "t")
    #expect(http.requests.last?.method == "DELETE")
  }

  @Test("attaching makes a driver that does nothing until started")
  func attachMakesADriver() async throws {
    let store = RemoteBrowserStore(sessionID: "s", tabID: "t")
    store.attach(using: try connector(), mode: .view, hostID: "h")
    store.setVisible(true)
    #expect(try await eventually(seconds: 5) { store.snapshot.connection != .idle })
    store.detach()
  }
}

@Suite("The system pasteboard, kept off the user's", .serialized)
struct SystemPasteboardTests {
  @Test("what a remote page copies can be pasted back")
  func roundTrip() {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    let pasteboard = SystemPasteboard()
    #expect(pasteboard.read() == nil)
    pasteboard.write("copied")
    #expect(pasteboard.read() == "copied")
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "copied")
    pasteboard.write("replaced")
    #expect(pasteboard.read() == "replaced")
  }
}

@Suite("Viewport modes that only matter on mobile")
struct MobileViewportTests {
  @Test("asking for the mobile site reloads the page, once, and only in Mobile Size")
  func requestMobileWebsite() {
    let hosted = HostedStore(mode: .mobile(site: false))
    defer { hosted.finish() }
    hosted.store.requestMobileWebsite(true)
    #expect(hosted.store.viewportMode == .mobile(site: true))
    #expect(hosted.store.viewportMode.requestsMobileSite)
    #expect(hosted.driverCalls.filter { $0.hasPrefix("nav reload") }.count == 1)
    hosted.store.requestMobileWebsite(true)
    #expect(hosted.driverCalls.filter { $0.hasPrefix("nav reload") }.count == 1)

    hosted.store.viewportMode = .keep
    hosted.store.requestMobileWebsite(true)
    #expect(hosted.store.viewportMode == .keep)
    #expect(!hosted.store.viewportMode.requestsMobileSite)
  }

  @Test("only desktop layouts have the page's own scroll bars")
  func scrollBars() {
    #expect(RemoteViewportMode.keep.hasPageScrollBars)
    #expect(!RemoteViewportMode.mobile(site: false).hasPageScrollBars)
  }
}

@Suite("A fixture stream that can't be played")
struct FixtureStreamFailureTests {
  @Test("a missing or malformed stream says what's wrong")
  func failures() {
    #expect(
      FixtureStreamError.missingResource("a").description == "The fixture a is not in the bundle.")
    #expect(
      FixtureStreamError.malformed("b").description == "The fixture is malformed: b")
    #expect(throws: FixtureStreamError.self) { try FixtureVideoStream(named: "no-such-stream") }
    #expect(throws: FixtureStreamError.self) {
      try FixtureVideoStream(
        annexB: Data(), index: Data("not json".utf8), streamID: 1, formatChanged: false)
    }
    let outside =
      #"{"width":1,"height":1,"frames":[{"index":0,"offset":0,"length":9,"keyframe":true,"pts_us":0}]}"#
    #expect(throws: FixtureStreamError.self) {
      try FixtureVideoStream(
        annexB: Data(), index: Data(outside.utf8), streamID: 1, formatChanged: false)
    }
  }
}
