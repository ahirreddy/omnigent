import Foundation
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppBrowser
@testable import OmnigentBrowser

/// A page the agent drives, whose snapshot the test decides.
private final class SnapshotTab: BrowserTab {
  let engineKind = BrowserEngineKind.system
  let profile = BrowserProfile(identifier: "mirror", persistence: .ephemeral)
  let state = BrowserTabState()
  let platformView = BrowserPlatformView(frame: .zero)
  weak var delegate: (any BrowserTabDelegate)?
  var popupPolicy = BrowserPopupPolicy.allow
  var urlPolicy: (any BrowserURLPolicy)?
  var agentInput: any BrowserAgentInput { fatalError("the mirror never drives the page") }
  var navigationHistory: BrowserNavigationHistory { .empty }
  var engineRestoreData: Data? { nil }

  let snapshot: () throws(BrowserError) -> Data
  private(set) var snapshots = 0

  init(snapshot: @escaping () throws(BrowserError) -> Data) {
    self.snapshot = snapshot
  }

  func takeSnapshotPNG() throws(BrowserError) -> Data {
    snapshots += 1
    return try snapshot()
  }

  func load(_ url: URL) {}
  func goBack() {}
  func goForward() {}
  func reload() {}
  func reload(ignoringCache: Bool) {}
  func stopLoading() {}
  func evaluateJavaScript(_ script: String) throws(BrowserError) -> BrowserScriptValue {
    .undefined
  }
  func find(_ text: String, forward: Bool, caseSensitive: Bool) throws(BrowserError)
    -> BrowserFindResult
  {
    BrowserFindResult(matchFound: false, matchCount: nil, activeMatch: nil)
  }
  func stopFinding() {}
  func showDevTools() throws(BrowserError) {}
  func setZoomFactor(_ factor: Double) {}
  func setAudioMuted(_ muted: Bool) {}
  func restoreEngineState(_ data: Data) -> Bool { false }
  func printPage() throws(BrowserError) {}
  func viewSourceURL() throws(BrowserError) -> URL { throw .tabNotReady }
  func close() {}
}

/// What a person sees of the page an agent is browsing.
@MainActor
@Suite("Agent browser mirror", .serialized, .timeLimit(.minutes(1)))
struct AgentBrowserMirrorTests {
  private func onePixelPNG() throws -> Data {
    try #require(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
      ))
  }

  private func mirror(_ tab: SnapshotTab) -> OffscreenWindow<AgentBrowserMirror> {
    OffscreenWindow(AgentBrowserMirror(tab: tab), width: 500, height: 300)
  }

  /// Waits on the main actor's queue for the mirror's first snapshot to land.
  private func settle(_ screen: OffscreenWindow<AgentBrowserMirror>, _ tab: SnapshotTab)
    async throws
  {
    let deadline = ContinuousClock.now + .seconds(5)
    while tab.snapshots == 0, ContinuousClock.now < deadline {
      screen.settle(0.005)
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(tab.snapshots > 0, "the mirror asked for a picture")
    screen.settle(0.02)
    try await Task.sleep(for: .milliseconds(5))
    screen.settle(0.02)
  }

  @Test("The page's picture shows under a read-only notice and the address")
  func aPicture() async throws {
    let png = try onePixelPNG()
    #expect(AgentBrowserMirror.image(from: png) != nil, "the picture decodes")
    let tab = SnapshotTab { () throws(BrowserError) -> Data in png }
    tab.state.url = URL(string: "https://example.com/agent")
    tab.state.title = "Agent page"
    let screen = mirror(tab)
    defer { screen.close() }
    try await settle(screen, tab)
    #expect(try screen.shows("The agent is browsing. This view is read-only."))
    #expect(try screen.shows("https://example.com/agent"))
    #expect(try !screen.shows("No Picture of the Page"))
  }

  @Test("A snapshot the engine refuses says why")
  func aRefusal() async throws {
    let tab = SnapshotTab { () throws(BrowserError) -> Data in
      throw .engineError(.system, message: "The renderer went away")
    }
    let screen = mirror(tab)
    defer { screen.close() }
    try await settle(screen, tab)
    #expect(try screen.shows("No Picture of the Page"))
  }

  @Test("A snapshot that isn't a picture says so instead of a spinner that never ends")
  func notAPicture() async throws {
    let tab = SnapshotTab { () throws(BrowserError) -> Data in Data([1, 2, 3]) }
    let screen = mirror(tab)
    defer { screen.close() }
    try await settle(screen, tab)
    #expect(try screen.shows("No Picture of the Page"))
    #expect(try screen.shows("The page's picture could not be read."))
  }

  @Test("The picture is read again while the page shows, and not after")
  func refreshing() async throws {
    let picture = try onePixelPNG()
    let tab = SnapshotTab { picture }
    let screen = OffscreenWindow(
      AgentBrowserMirror(tab: tab, refreshInterval: .milliseconds(5)), width: 500, height: 300)
    let deadline = ContinuousClock.now + .seconds(5)
    while tab.snapshots < 3, ContinuousClock.now < deadline {
      screen.settle(0.005)
      try await Task.sleep(for: .milliseconds(5))
    }
    #expect(tab.snapshots >= 3)
    screen.close()
    try await Task.sleep(for: .milliseconds(30))
    let afterClosing = tab.snapshots
    try await Task.sleep(for: .milliseconds(30))
    #expect(tab.snapshots == afterClosing)
  }
}
