#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// The menu bar extra's panel and icon.
  @MainActor
  @Suite("Menu bar panel", .serialized)
  struct MenuBarPanelTests {
    init() { DesktopSideEffects.reset() }

    private func hosted(
      _ fixture: DesktopFixture, sessions: (any MenuBarSessionSource)? = nil
    ) -> OffscreenWindow<OmnigentMenuBarContent> {
      OffscreenWindow(
        OmnigentMenuBarContent(desktop: fixture.desktop, sessions: sessions),
        width: 340, height: 720)
    }

    /// The panel's last rows, counted from the end: Quit, Settings, Show Server Logs, Open, New.
    private func row(
      _ fromEnd: Int, _ screen: OffscreenWindow<OmnigentMenuBarContent>
    ) throws -> CGRect {
      let rows = screen.controlFrames
      try #require(rows.count > fromEnd, "\(rows)")
      return rows[rows.count - 1 - fromEnd]
    }

    @Test("the panel starts this Mac's server, then offers to stop it")
    func startsServer() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      let url = try loopback(6767)
      fixture.local.runner.script(announces(6767))
      fixture.local.probe.answer(url, .ready(nil))
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Local Server"))
      try screen.click(screen.controlFrames[0])
      #expect(await settle(screen) { fixture.manager.server.endpoint?.url == url })
      await flush(screen)
      #expect(try screen.allText().contains("Stop"))
      try screen.click(screen.controlFrames[0])
      #expect(await settle(screen) { fixture.manager.server.endpoint == nil })
    }

    @Test("Host waits for a server, then hosts this Mac's without asking and can stop")
    func hostsOwnServer() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      let idle = hosted(fixture)
      defer { idle.close() }
      await flush(idle)
      let idleRows = idle.controlFrames.count

      let url = try await fixture.startServer()
      fixture.local.runner.script { $0.print("\u{2713} Connected as 'mac'.") }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      #expect(screen.controlFrames.count == idleRows + 1, "Host's Start came on")
      try screen.click(screen.controlFrames[1])
      #expect(await settle(screen) { fixture.manager.host == .connected(serverURL: url, .owned) })
      #expect(SystemSideEffects.record.alertMessages.isEmpty)
      await flush(screen)
      try screen.click(screen.controlFrames[1])
      #expect(await settle(screen) { fixture.manager.host == .stopped })
      await fixture.manager.stopOwnedProcesses()
    }

    @Test("a default server that's remote asks before hosting")
    func hostsRemoteAfterAsking() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.preferences.defaultServerURL = try url("https://team.test")
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      try screen.click(screen.controlFrames[1])
      #expect(await settle(screen) { !SystemSideEffects.record.alertMessages.isEmpty })
      #expect(SystemSideEffects.record.alertMessages == ["Allow agents to run on this Mac?"])
      await flush(screen)
      #expect(fixture.manager.host == .stopped, "the alert's first answer is Cancel")
    }

    @Test("an edition without a local server explains itself and drops the server rows")
    func unavailable() throws {
      let fixture = try DesktopFixture(capability: .unavailable(.appSandbox))
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      let text = try screen.allText()
      #expect(text.contains("App Sandbox"))
      #expect(!text.contains("Local Server"))
      #expect(!text.contains("Show Server Logs"))
    }

    @Test("sessions needing attention say why, and a click opens that conversation")
    func attention() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let server = try url("https://team.test")
      let sessions = FakeMenuBarSessionSource.sample(serverURL: server)
      let screen = hosted(fixture, sessions: sessions)
      defer { screen.close() }
      await flush(screen)
      let text = try screen.allText()
      #expect(text.contains("1 need you"))
      #expect(text.contains("Waiting for your answer"))
      #expect(text.contains("Turn failed"))
      #expect(text.contains("3 unread"))
      var opened: [ServerWindowID] = []
      fixture.desktop.router.confirmUnknownServer = { _ in true }
      fixture.desktop.router.attachWindowOpener { opened.append($0) }
      let rows = screen.controlFrames.filter { $0.height > 28 && $0.height < 40 }
      try #require(rows.count == 3, "\(screen.controlFrames)")
      try screen.click(rows[0])
      #expect(await settle(screen) { !opened.isEmpty })
      #expect(opened.first?.serverURL == server)
      #expect(SystemSideEffects.record.activationCount >= 1, "the app comes forward")
      let window = try #require(opened.first?.instance)
      #expect(
        fixture.desktop.registry.pendingRoute(for: window)
          == .conversation(sessionID: "conv_review"))
    }

    @Test("nothing needing attention says so, and one unread reads singular")
    func quiet() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture, sessions: FakeMenuBarSessionSource())
      defer { screen.close() }
      #expect(try screen.allText().contains("Nothing needs you right now."))
      let one = AttentionSession(
        id: "c", title: "One", serverURL: try url("https://team.test"), reason: .unread(count: 1),
        updatedAt: Date())
      let single = hosted(
        fixture, sessions: FakeMenuBarSessionSource(sessions: [one], unreadCount: 0))
      defer { single.close() }
      #expect(try single.allText().contains("1 unread"))
      #expect(try !single.allText().contains("need you"), "no count while it's zero")
    }

    @Test("Quit quits and Settings comes forward")
    func quitAndSettings() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      try screen.click(try row(0, screen))
      #expect(SystemSideEffects.record.terminationCount == 1)
      try screen.click(try row(1, screen))
      #expect(SystemSideEffects.record.activationCount == 1)
      try screen.click(try row(2, screen))
      #expect(SystemSideEffects.record.activationCount == 2, "Show Server Logs too")
    }

    @Test("Open Omnigent brings a window forward when there's one")
    func openOmnigent() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      try screen.click(try row(3, screen))
      #expect(SystemSideEffects.record.activationCount == 1)
      #expect(!SystemSideEffects.record.shownWindowTitles.isEmpty)
    }

    @Test("New Session opens home on the local or default server")
    func newSession() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var opened: [ServerWindowID] = []
      fixture.desktop.router.confirmUnknownServer = { _ in true }
      fixture.desktop.router.attachWindowOpener { opened.append($0) }
      let server = try url("https://team.test")
      fixture.desktop.preferences.defaultServerURL = server
      let screen = hosted(fixture)
      defer { screen.close() }
      // The panel attaches its own opener as it appears; take it back for the check.
      await flush(screen)
      fixture.desktop.router.attachWindowOpener { opened.append($0) }
      try screen.click(try row(4, screen))
      #expect(await settle(screen) { opened.first?.serverURL == server })
    }

    @Test("New Session with no server goes to the connect screen without routing")
    func newSessionNoServer() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let screen = hosted(fixture)
      defer { screen.close() }
      await flush(screen)
      var routed = 0
      fixture.desktop.router.attachWindowOpener { _ in routed += 1 }
      try screen.click(try row(4, screen))
      await flush(screen)
      #expect(routed == 0)
      #expect(SystemSideEffects.record.activationCount == 1)
    }

    @Test("the icon is filled while the server runs, and counts who needs you")
    func label() throws {
      let running = OmnigentMenuBarLabel.icon(isServerRunning: true)
      #expect(running !== OmnigentMenuBarLabel.icon(isServerRunning: false))
      #expect(running === OmnigentMenuBarLabel.icon(isServerRunning: true), "one image per state")
      let counted = OffscreenWindow(
        OmnigentMenuBarLabel(state: MenuBarLabelState(isServerRunning: true, unreadCount: 2)),
        width: 240, height: 40)
      defer { counted.close() }
      #expect(try counted.allText().contains("Omnigent, 2 need you"))
      let quiet = OffscreenWindow(
        OmnigentMenuBarLabel(state: MenuBarLabelState(isServerRunning: false, unreadCount: 0)),
        width: 240, height: 40)
      defer { quiet.close() }
      #expect(try !quiet.allText().contains("need you"))
    }

    @Test("a row lights up while hovered")
    func hoverRow() async throws {
      var clicks = 0
      let screen = OffscreenWindow(
        MenuRowButton("Row", systemImage: "gearshape") { clicks += 1 }, width: 200, height: 40)
      defer { screen.close() }
      let frame = try #require(screen.controlFrames.first)
      try screen.hover(CGPoint(x: frame.midX, y: frame.midY))
      await flush(screen)
      try screen.click(frame)
      try screen.endHover()
      #expect(clicks == 1)
    }
  }
#endif
