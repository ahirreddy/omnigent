#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  @Observable
  private final class Host {
    var isCollapsed = true
  }

  @Suite("Adaptive: the sidebar peek", .serialized)
  @MainActor
  struct AdaptivePeekTests {
    private struct PeekHarness: View {
      let host: Host
      var startsShown = false

      var body: some View {
        Color.clear
          .modifier(
            SidebarPeekOverlay(isCollapsed: host.isCollapsed, startsShown: startsShown) {
              Text("peek panel")
            })
      }
    }

    private func tracker(_ screen: OffscreenWindow<AnyView>) -> NSView? {
      screen.allViews.first { String(describing: Swift.type(of: $0)).contains("TrackingView") }
    }

    private func moved(_ screen: OffscreenWindow<AnyView>, toX pointX: CGFloat) throws -> NSEvent {
      try #require(
        NSEvent.mouseEvent(
          with: .mouseMoved, location: CGPoint(x: pointX, y: 100), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: screen.window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 0, pressure: 0))
    }

    private func screen(
      _ host: Host, startsShown: Bool = false, direction: LayoutDirection = .leftToRight
    )
      -> OffscreenWindow<AnyView>
    {
      OffscreenWindow(
        AnyView(
          PeekHarness(host: host, startsShown: startsShown).environment(
            \.layoutDirection, direction)
        ), width: 800, height: 500)
    }

    /// Waits out a peek delay: the timer runs on the main actor.
    private func wait(_ duration: Duration, _ screen: OffscreenWindow<AnyView>) async throws {
      try await Task.sleep(for: duration + .milliseconds(30))
      screen.settle(0.05)
    }

    @Test("Resting on the leading edge reveals the panel, after a moment")
    func reveals() async throws {
      let host = Host()
      let screen = screen(host)
      defer { screen.close() }
      let view = try #require(tracker(screen))
      #expect(try !screen.shows("peek panel"))
      try view.mouseEntered(with: moved(screen, toX: 2))
      screen.settle(0.02)
      #expect(try !screen.shows("peek panel"))
      try await wait(SidebarPeek.revealDelay, screen)
      #expect(try screen.shows("peek panel"))
    }

    @Test("Passing over the edge doesn't flash the panel")
    func passingOver() async throws {
      let host = Host()
      let screen = screen(host)
      defer { screen.close() }
      let view = try #require(tracker(screen))
      try view.mouseMoved(with: moved(screen, toX: 2))
      // The reveal's timer is running when the pointer moves on: it gets cancelled.
      try await wait(.milliseconds(20), screen)
      try view.mouseMoved(with: moved(screen, toX: 300))
      try await wait(SidebarPeek.revealDelay, screen)
      #expect(try !screen.shows("peek panel"))
    }

    @Test("Moving off the panel hides it after a moment, and leaving the window does too")
    func hides() async throws {
      let host = Host()
      let screen = screen(host, startsShown: true)
      defer { screen.close() }
      let view = try #require(tracker(screen))
      #expect(try screen.shows("peek panel"))
      try view.mouseMoved(with: moved(screen, toX: 100))
      try await wait(SidebarPeek.hideDelay, screen)
      #expect(try screen.shows("peek panel"))

      try view.mouseExited(with: moved(screen, toX: 0))
      try await wait(SidebarPeek.hideDelay, screen)
      screen.settle(0.3)
      #expect(try !screen.shows("peek panel"))
    }

    @Test("In a right-to-left window the edge is on the right")
    func rightToLeft() async throws {
      let host = Host()
      let screen = screen(host, direction: .rightToLeft)
      defer { screen.close() }
      let view = try #require(tracker(screen))
      try view.mouseMoved(with: moved(screen, toX: 2))
      try await wait(SidebarPeek.revealDelay, screen)
      #expect(try !screen.shows("peek panel"))
      try view.mouseMoved(with: moved(screen, toX: 798))
      try await wait(SidebarPeek.revealDelay, screen)
      #expect(try screen.shows("peek panel"))
    }

    @Test("A sheet over the window stops the edge from revealing the panel")
    func blockedBySheet() async throws {
      let host = Host()
      let screen = screen(host)
      defer { screen.close() }
      let view = try #require(tracker(screen))
      let sheet = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
      screen.window.beginSheet(sheet, completionHandler: nil)
      defer { screen.window.endSheet(sheet) }
      try view.mouseMoved(with: moved(screen, toX: 2))
      try await wait(SidebarPeek.revealDelay, screen)
      #expect(try !screen.shows("peek panel"))
    }

    @Test("The tracker takes no clicks, and keeps one tracking area")
    func trackerStaysOutOfTheWay() throws {
      let host = Host()
      let screen = screen(host)
      defer { screen.close() }
      let view = try #require(tracker(screen))
      #expect(view.hitTest(CGPoint(x: 5, y: 5)) == nil)
      view.updateTrackingAreas()
      view.updateTrackingAreas()
      #expect(view.trackingAreas.count == 1)
    }

    @Test("A pinned sidebar has no peek or tracker, and pinning ends a peek")
    func pinning() throws {
      let host = Host()
      let screen = screen(host, startsShown: true)
      defer { screen.close() }
      #expect(try screen.shows("peek panel"))
      host.isCollapsed = false
      screen.settle(0.4)
      #expect(try !screen.shows("peek panel"))
      #expect(tracker(screen) == nil)
      host.isCollapsed = true
      screen.settle(0.4)
      #expect(try !screen.shows("peek panel"))
    }
  }
#endif
