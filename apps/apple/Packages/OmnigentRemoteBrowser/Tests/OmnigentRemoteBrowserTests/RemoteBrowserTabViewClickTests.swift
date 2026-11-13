#if os(macOS)
  import AppKit
  import OmnigentCoreFFI
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentRemoteBrowser

  /// Collects the addresses a tab asked to reopen.
  @MainActor
  private final class ReopenLog {
    var addresses: [String] = []
  }

  extension OffscreenWindow {
    /// Clicks the middle of a frame.
    fileprivate func clickMiddle(of frame: CGRect) throws {
      try click(CGPoint(x: frame.midX, y: frame.midY))
    }
  }

  /// The remote tab's own controls, pressed with real mouse events in a window.
  @MainActor
  @Suite("Remote browser tab, clicked", .serialized)
  struct RemoteBrowserTabViewClickTests {
    private static let ended = RemoteBrowserConnection.closed(
      reason: .tabEnded(reason: nil, detail: ""))

    @Test("Reopen on an ended tab asks for a new tab at the address it last showed")
    func reopen() async throws {
      let hosted = HostedStore(lastURL: "https://example.com/docs")
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(connection: Self.ended))
      let log = ReopenLog()
      let screen = OffscreenWindow(
        RemoteBrowserTabView(store: hosted.store, reopen: { log.addresses.append($0) }),
        width: 900, height: 600)
      defer { screen.close() }
      #expect(try screen.shows("This remote tab ended"))
      #expect(try screen.shows("Reopen"))
      let lastURL = hosted.store.lastURL
      #expect(!lastURL.isEmpty)
      #expect(try screen.shows(lastURL))
      // Reopen is under the toolbar, in the middle of the page.
      let button = try #require(screen.controlFrames.last)
      #expect(button.minY > 100, "\(button)")
      try screen.clickMiddle(of: button)
      #expect(log.addresses == [lastURL])
    }

    @Test("an ended tab that nothing can reopen offers no button")
    func noReopen() async throws {
      let hosted = HostedStore(lastURL: "https://example.com/docs")
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(connection: Self.ended))
      let screen = OffscreenWindow(
        RemoteBrowserTabView(store: hosted.store), width: 900, height: 600)
      defer { screen.close() }
      #expect(try screen.shows("This remote tab ended"))
      #expect(try !screen.shows("Reopen"))
      #expect(screen.controlFrames.allSatisfy { $0.maxY < 100 }, "only the toolbar has controls")
    }

    @Test("Back, Forward and Reload each send their own navigation, and Stop while loading")
    func toolbar() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      var snapshot = HostedStore.snapshot()
      snapshot.nav?.canGoBack = true
      snapshot.nav?.canGoForward = true
      await hosted.hostSends(snapshot)
      let screen = OffscreenWindow(
        RemoteBrowserToolbar(store: hosted.store), width: 900, height: 60)
      defer { screen.close() }
      var navigations: [String] { hosted.driverCalls.filter { $0.hasPrefix("nav") } }
      let buttons = Array(screen.controlFrames.prefix(3))
      try #require(buttons.count == 3)
      try screen.clickMiddle(of: buttons[0])
      #expect(navigations == ["nav back "])
      try screen.clickMiddle(of: buttons[1])
      #expect(navigations == ["nav back ", "nav forward "])
      try screen.clickMiddle(of: buttons[2])
      #expect(navigations == ["nav back ", "nav forward ", "nav reload "])
      snapshot.nav?.loading = true
      await hosted.hostSends(snapshot)
      screen.settle()
      try screen.clickMiddle(of: try #require(screen.controlFrames.dropFirst(2).first))
      #expect(navigations.last == "nav stop ")
    }

    @Test("Take Over asks the host for control, and Hand Back gives it up")
    func control() async throws {
      let hosted = HostedStore()
      defer { hosted.finish() }
      await hosted.hostSends(HostedStore.snapshot(owner: .agent, holder: .nobody))
      let screen = OffscreenWindow(
        RemoteBrowserControlStrip(store: hosted.store), width: 900, height: 40)
      defer { screen.close() }
      #expect(try screen.shows("Take Over"))
      try screen.clickMiddle(of: try #require(screen.controlFrames.last))
      #expect(hosted.driverCalls.last == "take")
      await hosted.hostSends(HostedStore.snapshot())
      screen.settle()
      #expect(try screen.shows("Hand Back to Agent"))
      try screen.clickMiddle(of: try #require(screen.controlFrames.last))
      #expect(hosted.driverCalls.last == "release")
    }
  }
#endif
