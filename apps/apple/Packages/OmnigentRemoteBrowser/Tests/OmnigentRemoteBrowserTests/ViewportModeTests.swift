import CoreGraphics
import Foundation
import OmnigentCoreFFI
import Testing

@testable import OmnigentRemoteBrowser

/// The viewport modes, what they ask the host for, and the store applying them, copying and
/// pasting, and filtering notices (design doc sections 16.1, 16.2 and 16.5).
@MainActor
@Suite("Remote browser viewport modes and edit", .serialized)
struct ViewportModeTests {
  private let phone = CGSize(width: 393, height: 659.5)

  @Test("saving a mode whose bytes aren't text fails instead of clearing the saved mode")
  func unsavableMode() {
    #expect(throws: CocoaError.self) {
      _ = try RemoteViewportModeDefaults.text(of: Data([0xFF]))
    }
  }

  private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<200 {
      if condition() { return true }
      try await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }

  @Test func eachModeAsksForItsViewport() {
    #expect(RemoteViewportMode.keep.request(viewSize: phone, screenScale: 3) == nil)
    #expect(
      RemoteViewportMode.fitWindow.request(viewSize: phone, screenScale: 3)
        == RemoteViewportRequest(
          viewport: RemoteViewport(width: 393, height: 660, dpr: 1), mobile: .off))
    #expect(
      RemoteViewportMode.mobile(site: false).request(viewSize: phone, screenScale: 3)
        == RemoteViewportRequest(
          viewport: RemoteViewport(width: 393, height: 660, dpr: 3), mobile: .layout))
    #expect(
      RemoteViewportMode.mobile(site: true).request(viewSize: phone, screenScale: 3)?.mobile
        == .site)
    let fixed = RemoteViewportMode.fixed(RemoteViewportSize(width: 9000, height: 100, dpr: 2))
    #expect(
      fixed.request(viewSize: phone, screenScale: 3)?.viewport
        == RemoteViewport(width: 3840, height: 200, dpr: 2), "clamped to the protocol bounds")
    #expect(RemoteViewportMode.mobile(site: false).followsView)
    #expect(!RemoteViewportMode.keep.followsView)
    #expect(!RemoteViewportMode.mobile(site: false).allowsDoubleTapZoom)
    #expect(RemoteViewportMode.fitWindow.allowsDoubleTapZoom)
  }

  @Test func modesPersistPerDevice() throws {
    let defaults = try #require(UserDefaults(suiteName: "remote-viewport-mode-tests"))
    defaults.removePersistentDomain(forName: "remote-viewport-mode-tests")
    #expect(RemoteViewportModeDefaults.load(defaults) == .keep)
    for mode in [
      RemoteViewportMode.mobile(site: true), .fitWindow,
      .fixed(RemoteViewportSize(width: 1440, height: 900, dpr: 2)),
    ] {
      try RemoteViewportModeDefaults.save(mode, defaults)
      #expect(RemoteViewportModeDefaults.load(defaults) == mode)
    }
    defaults.set("not json", forKey: RemoteViewportModeDefaults.key)
    #expect(RemoteViewportModeDefaults.load(defaults) == .keep)
    // The launch-argument form UI tests use.
    defaults.set(#"{"mobile":{"site":false}}"#, forKey: RemoteViewportModeDefaults.key)
    #expect(RemoteViewportModeDefaults.load(defaults) == .mobile(site: false))
  }

  @Test func theStoreFollowsTheViewInMobileSizeAndRestoresOnKeep() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(5))
    host.addTab(id: "btab_1", url: "https://example.com/")
    let store = RemoteBrowserStore(sessionID: "conv_a", tabID: "btab_1")
    store.viewportMode = .keep
    defer { store.viewportMode = .keep }
    store.attach(using: host, mode: .control, hostID: nil)
    #expect(try await eventually { store.snapshot.connection == .attached(mode: .control) })
    store.viewportMode = .mobile(site: false)
    store.viewChanged(size: phone, scale: 3)
    #expect(try await eventually { store.snapshot.viewport?.width == 393 })
    #expect(store.snapshot.viewport?.dpr == 3)
    #expect(store.snapshot.mobile == .layout)
    #expect(store.showsOwnViewport)
    // Rotation: the remote follows once the size settles.
    store.viewChanged(size: CGSize(width: 852, height: 300), scale: 3)
    #expect(try await eventually { store.snapshot.viewport?.width == 852 })
    store.viewportMode = .keep
    #expect(try await eventually { store.snapshot.viewport?.width == 1280 })
    #expect(!store.showsOwnViewport)
    store.detach()
  }

  @Test func copyAndPasteUseTheLocalPasteboard() async throws {
    let host = FixtureRemoteBrowser(latency: .milliseconds(5))
    host.addTab(id: "btab_1", url: "https://example.com/")
    let store = RemoteBrowserStore(sessionID: "conv_a", tabID: "btab_1")
    let pasteboard = MemoryPasteboard()
    store.pasteboard = pasteboard
    store.attach(using: host, mode: .control, hostID: nil)
    #expect(try await eventually { store.canEdit })
    store.copy()
    #expect(try await eventually { pasteboard.text == "fixture selection" })
    pasteboard.text = "from the phone"
    store.paste()
    store.selectAll()
    let driver = try #require(store.fixtureDriver)
    #expect(try await eventually { driver.inputLog.contains("edit paste from the phone") })
    #expect(driver.inputLog.contains("edit selectAll"))
    pasteboard.text = nil
    store.paste()
    #expect(store.notice == "The pasteboard has no text to paste.")
    store.detach()
  }
}

/// A pasteboard in memory.
final class MemoryPasteboard: RemotePasteboard {
  var text: String?

  func write(_ text: String) { self.text = text }
  func read() -> String? { text }
}
