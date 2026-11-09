import AppKit
import Foundation
import OmnigentViewTesting
import SwiftUI
import Testing
import WebKit

@testable import OmnigentBrowser

/// A web view whose snapshots fail, as they do when its web process is gone.
private final class FailingWebView: WKWebView {
  override func takeSnapshot(
    with snapshotConfiguration: WKSnapshotConfiguration?,
    completionHandler: @escaping @MainActor (NSImage?, (any Error)?) -> Void
  ) {
    completionHandler(nil, CocoaError(.featureUnsupported))
  }
}

private struct RemovalRefused: Error {}

@MainActor
@Suite("System tab failures", .serialized)
struct SystemTabFailureTests {
  /// Runs a script in the bridge's own world, out of the page's reach.
  private func runInBridgeWorld(_ script: String, on tab: SystemBrowserTab) async throws {
    _ = try await tab.webView.evaluateJavaScript(
      script, in: nil, contentWorld: SystemPageBridge.world)
  }

  @Test("a page that breaks the selection API gets its find failure reported")
  func stopFindingFails() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load(
      "<script>window.getSelection = () => { throw new Error('no selection') }</script>")
    fixture.tab.stopFinding()
    #expect(
      try await waitUntil {
        if case .findFailed = fixture.tab.state.lastError { true } else { false }
      })
  }

  @Test("muting that fails in a live frame is reported")
  func muteFails() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    try await fixture.load("<p>Loud</p>")
    #expect(try await waitUntil { !tab.bridgeFrames.isEmpty })
    try await runInBridgeWorld(
      "globalThis.__omnigentBrowser.setMuted = () => { throw new Error('boom') }; true", on: tab)
    tab.setAudioMuted(true)
    #expect(
      try await waitUntil {
        guard case .scriptFailed(let message) = tab.state.lastError else { return false }
        return message.hasPrefix("Muting failed: ")
      })
  }

  @Test("muting a frame that went away isn't an error")
  func muteGoneFrame() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    let tab = fixture.tab
    try await fixture.load("<iframe id=inner srcdoc='<p>Inner</p>'></iframe>")
    #expect(try await waitUntil { tab.bridgeFrames.values.contains { !$0.isMainFrame } })
    let inner = try #require(tab.bridgeFrames.values.first { !$0.isMainFrame })
    _ = try await tab.evaluateJavaScript("document.getElementById('inner').remove(); true")
    tab.applyMute(in: inner)
    // A round trip after the mute, so its answer has arrived.
    _ = try await tab.evaluateJavaScript("1")
    #expect(tab.state.lastError == nil)
  }

  @Test("a page whose source isn't text has none to show")
  func noSource() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load("<p>Page</p>")
    _ = try await fixture.tab.evaluateJavaScript(
      "Object.defineProperty(document.documentElement, 'outerHTML', { get() { return 5 } }); true")
    await #expect(throws: BrowserError.scriptFailed(message: "The page has no source to show.")) {
      try await fixture.tab.viewSourceURL()
    }
  }

  @Test("a snapshot WebKit can't take says why")
  func snapshotFails() async throws {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let tab = SystemBrowserTab(
      profile: .ephemeral("snapshot-\(UUID().uuidString)"), configuration: configuration,
      makeWebView: { FailingWebView(frame: .zero, configuration: $0) })
    defer { tab.close() }
    await #expect {
      try await tab.takeSnapshotPNG()
    } throws: { error in
      if case .snapshotFailed = error as? BrowserError { true } else { false }
    }
  }

  @Test("finding nothing answers without a match")
  func findEmpty() async throws {
    let fixture = try SystemTabFixture()
    defer { fixture.tab.close() }
    try await fixture.load("<p>Needle</p>")
    let result = try await fixture.tab.find("", forward: true, caseSensitive: false)
    #expect(!result.matchFound)
  }

  @Test("a store that stays busy is tried five times, longer each time, then queued")
  func storeStaysBusy() async throws {
    let defaults = try isolatedDefaults()
    let identifier = UUID()
    var attempts = 0
    await SystemBrowserEngine.removeStore(
      identifier,
      remove: { _ in
        attempts += 1
        throw RemovalRefused()
      },
      retryDelay: .milliseconds(1), defaults: defaults)
    #expect(attempts == 5)
    #expect(
      defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey)
        == [identifier.uuidString])
  }

  @Test("a store that lets go on a retry leaves nothing queued")
  func storeLetsGo() async throws {
    let defaults = try isolatedDefaults()
    var attempts = 0
    await SystemBrowserEngine.removeStore(
      UUID(),
      remove: { _ in
        attempts += 1
        if attempts < 3 { throw RemovalRefused() }
      },
      retryDelay: .milliseconds(1), defaults: defaults)
    #expect(attempts == 3)
    #expect(defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey) == nil)
  }

  @Test("giving up early still queues the store for the next launch")
  func cancelledRemoval() async throws {
    let defaults = try isolatedDefaults()
    let identifier = UUID()
    let removal = Task { @MainActor in
      withUnsafeCurrentTask { $0?.cancel() }
      await SystemBrowserEngine.removeStore(
        identifier, remove: { _ in throw RemovalRefused() }, retryDelay: .seconds(60),
        defaults: defaults)
    }
    await removal.value
    #expect(
      defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey)
        == [identifier.uuidString])
  }

  @Test("a queued store that still can't go stays queued; the rest leave the queue")
  func queuedStoreStays() async throws {
    let defaults = try isolatedDefaults()
    let (stuck, freed) = (UUID(), UUID())
    defaults.set(
      [stuck.uuidString, freed.uuidString], forKey: SystemBrowserEngine.pendingRemovalKey)
    await SystemBrowserEngine.removeQueuedStores(
      remove: { identifier in
        if identifier == stuck { throw RemovalRefused() }
      },
      defaults: defaults)
    #expect(
      defaults.stringArray(forKey: SystemBrowserEngine.pendingRemovalKey) == [stuck.uuidString])
  }
}

/// The agent's private window for an engine that renders only inside one.
@MainActor
@Suite("Agent page window", .serialized)
struct AgentPageWindowTests {
  @Test("a page needing a window gets a click-proof panel off every screen, until it closes")
  func hostPanel() throws {
    // Sets the test process up as an accessory app, so the panel never reaches the Dock.
    OffscreenWindow(Color.clear).close()
    let tab = AgentFakeTab(profile: .ephemeral("panel"))
    tab.recorder.needsHostWindow = true
    let viewport = CGSize(width: 640, height: 480)
    let page = AgentPage(tab: tab, viewport: viewport)
    let panel = try #require(tab.platformView.window as? NSPanel)
    #expect(panel.ignoresMouseEvents)
    #expect(!panel.hidesOnDeactivate)
    #expect(panel.isExcludedFromWindowsMenu)
    #expect(!panel.canBecomeKey)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.collectionBehavior.contains(.transient))
    #expect(panel.frame.origin == CGPoint(x: -40_000, y: -40_000))
    #expect(tab.platformView.frame.size == viewport)
    #expect(tab.recorder.preparedViewport == viewport)
    page.close()
    #expect(tab.state.isClosed)
    #expect(tab.platformView.window == nil)
    #expect(!panel.isVisible)
  }

  @Test("a page rendered elsewhere gets no window")
  func noPanel() {
    let tab = AgentFakeTab(profile: .ephemeral("no-panel"))
    let page = AgentPage(tab: tab, viewport: CGSize(width: 10, height: 10))
    #expect(tab.platformView.window == nil)
    page.close()
    #expect(tab.state.isClosed)
  }
}
