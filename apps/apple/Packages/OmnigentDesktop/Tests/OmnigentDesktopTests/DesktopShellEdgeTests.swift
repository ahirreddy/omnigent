#if os(macOS)
  import AppKit
  import Darwin
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// The shell's rarer paths: defaults, refusals and states a running app seldom sees.
  @MainActor
  @Suite("Desktop shell edges", .serialized)
  struct DesktopShellEdgeTests {
    init() { DesktopSideEffects.reset() }

    /// What `body` writes to standard error.
    private func standardError(during body: () -> Void) throws -> String {
      let file = FileManager.default.temporaryDirectory
        .appending(path: "desktop-stderr-\(UUID().uuidString)")
      FileManager.default.createFile(atPath: file.path, contents: nil)
      defer {
        #expect(throws: Never.self) { try FileManager.default.removeItem(at: file) }
      }
      let output = try FileHandle(forWritingTo: file)
      let saved = dup(STDERR_FILENO)
      dup2(output.fileDescriptor, STDERR_FILENO)
      body()
      dup2(saved, STDERR_FILENO)
      close(saved)
      try output.close()
      return try String(contentsOf: file, encoding: .utf8)
    }

    @Test("with no reporter bound, a rejected link is written to standard error")
    func defaultReporter() throws {
      let router = DesktopRouter(registry: ServerWindowRegistry(reportIssue: { _ in }))
      let bad = try url("https://not-a-deep-link.test")
      let written = try standardError { router.open([bad]) }
      #expect(written.contains("[OmnigentDesktop]"))
      #expect(written.contains("deepLinkRejected"))
      #expect(written.contains("not-a-deep-link.test"))
    }

    @Test("with no reporter bound, the notification wrapper is still unavailable outside an app")
    func defaultNotificationCenter() {
      let center = DesktopNotificationCenter()
      #expect(center.authorization == .unknown)
      #expect(throws: DesktopNotificationError.self) { try center.installAsDelegate() }
    }

    @Test("every host the origin grammar allows forms a URL the router can open")
    func everyOriginHasAURL() throws {
      let hosts = [
        "[:]", "[::1]", "[12345::]", "[::ffff:1.2.3.4]", "a_b", "-a", "a-", "a.b.", "1.2.3.4",
        String(repeating: "a", count: 5_000),
      ]
      for host in hosts {
        let origin = try ServerOrigin(scheme: .https, host: host, port: 65_535)
        #expect(origin.url != nil, "\(host)")
      }
    }

    @Test("a queued window request that's cancelled opens nothing")
    func cancelledWindowRequest() async throws {
      var issues: [DesktopIssue] = []
      let registry = ServerWindowRegistry(reportIssue: { _ in })
      let router = DesktopRouter(registry: registry, reportIssue: { issues.append($0) })
      router.windowRequestDelay = .seconds(600)
      var requests = 0
      router.requestWindow = { requests += 1 }
      router.open(.home, onServer: try url("https://a.test"))
      let request = try #require(router.windowRequest)
      request.cancel()
      await request.value
      #expect(requests == 0)
      #expect(issues.count == 1, "still reports it's waiting: \(issues)")
    }

    @Test("a local server URL that isn't an http server is reported, with no offer to open it")
    func offerOnBadEndpoint() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var offers = 0
      fixture.desktop.confirmOpenLocalServer = { _ in
        offers += 1
        return true
      }
      var endpoint = try #require(LocalServerEndpoint(port: 6767, pid: nil, manifest: nil))
      endpoint.url = try url("file:///tmp/server")
      await fixture.desktop.offerWindow(on: endpoint)
      #expect(offers == 0)
      guard case .invalidServerURL = fixture.issues.issues.first else {
        Issue.record("expected a URL issue, got \(fixture.issues.issues)")
        return
      }
    }

    @Test("the reconnect monitor hands out its triggers")
    func reconnectMonitor() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let monitor = fixture.desktop.makeReconnectMonitor()
      var triggers = monitor.triggers.makeAsyncIterator()
      NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
      #expect(await triggers.next() != nil)
    }

    @Test("the delegate's default shell starts nothing and shows nothing")
    func defaultDelegate() {
      let delegate = OmnigentDesktopAppDelegate()
      #expect(delegate.desktop.localServer.server == .stopped)
      #expect(delegate.desktop.localServer.host == .stopped)
      #expect(delegate.desktop.registry.routingSnapshots.isEmpty)
      #expect(SystemSideEffects.record.shownWindowTitles.isEmpty)
    }

    @Test("a window's identity stays when its server changes")
    func windowIdentity() throws {
      var window = ServerWindowID.newWindow(serverURL: try url("https://a.test"))
      let identity = window.id
      #expect(identity == window.instance)
      window.serverURL = try url("https://b.test")
      #expect(window.id == identity)
    }

    @Test("an alert on an open window is a sheet there, and answers with its button")
    func alertSheet() async {
      let screen = OffscreenWindow(Color.clear, width: 200, height: 100)
      defer { screen.close() }
      let alert = NSAlert()
      alert.messageText = "Open it?"
      let answer = await DesktopAlert.present(alert, on: screen.window)
      #expect(answer == .alertFirstButtonReturn)
      #expect(SystemSideEffects.record.alertMessages == ["Open it?"])
    }

    @Test("Open Omnigent with no window showing brings no window forward, and activates")
    func openOmnigentWithNoWindows() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var panel = OmnigentMenuBarContent(desktop: fixture.desktop, sessions: nil)
      panel.openWindows = { [] }
      let screen = OffscreenWindow(panel, width: 340, height: 720)
      defer { screen.close() }
      await flush(screen)
      let rows = screen.controlFrames
      SystemSideEffects.reset()
      try screen.click(rows[rows.count - 4])
      #expect(SystemSideEffects.record.activationCount == 1)
      #expect(SystemSideEffects.record.shownWindowTitles.isEmpty)
    }

    @Test("a server answering over something other than HTTP is never taken for ready")
    func probeOfFileServer() async throws {
      let folder = FileManager.default.temporaryDirectory
        .appending(path: "probe-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: folder.appending(path: "v1"), withIntermediateDirectories: true)
      defer {
        #expect(throws: Never.self) { try FileManager.default.removeItem(at: folder) }
      }
      try Data("{}".utf8).write(to: folder.appending(path: "health"))
      try Data("{}".utf8).write(to: folder.appending(path: "v1/me"))
      let probe = URLSessionLocalServerProbe()
      guard case .notReady(let reason) = await probe.probe(folder) else {
        Issue.record("expected not ready")
        return
      }
      #expect(reason.contains("did not return an HTTP response"))
      #expect(await probe.signInProbe(folder, bearer: nil) == .unreachable)
    }
  }

  /// The Notifications tab when the system says no.
  @MainActor
  @Suite("Notification settings failures", .serialized)
  struct NotificationSettingsFailureTests {
    private struct Unlisted: LocalizedError {
      var errorDescription: String? { "the folder is gone" }
    }

    init() { DesktopSideEffects.reset() }

    @Test("sounds that can't be listed say why")
    func soundsUnlisted() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var tab = NotificationSettingsTab(
        preferences: fixture.desktop.preferences, notifications: fixture.desktop.notifications,
        isAvailable: false)
      tab.listSounds = { throw Unlisted() }
      let screen = OffscreenWindow(tab, width: 580, height: 640)
      defer { screen.close() }
      await flush(screen)
      #expect(try screen.allText().contains("Could not list system sounds: the folder is gone"))
    }

    @Test("System Settings opens on the app's row when it has an identifier")
    func settingsLink() throws {
      let named = DesktopNotificationCenter.systemSettingsURL(
        bundleIdentifier: "ai.omnigent.mac")
      #expect(
        named?.absoluteString
          == "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
          + "?id=ai.omnigent.mac")
      let unnamed = DesktopNotificationCenter.systemSettingsURL(bundleIdentifier: nil)
      #expect(
        unnamed?.absoluteString
          == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    @Test("System Settings refusing to open tells the user where to go")
    func settingsRefused() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      DesktopSideEffects.state.workspaceOpensFail = true
      fixture.desktop.notifications.authorization = .denied
      let screen = OffscreenWindow(
        NotificationSettingsTab(
          preferences: fixture.desktop.preferences, notifications: fixture.desktop.notifications,
          isAvailable: false),
        width: 580, height: 640)
      defer { screen.close() }
      await flush(screen)
      try screen.click(try #require(screen.controlFrames.first))
      await flush(screen)
      #expect(try screen.allText().contains("Open System Settings > Notifications to change this."))
    }
  }
#endif
