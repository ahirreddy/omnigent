#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentDesktop

  /// A window joined to the shell: what it tells the registry, and routes it receives.
  @MainActor
  @Suite("Server window", .serialized)
  struct ServerWindowTests {
    init() { DesktopSideEffects.reset() }

    /// A window's content whose state a test changes by swapping the root view.
    private struct Content: View {
      let id: Binding<ServerWindowID>
      let desktop: DesktopController
      var isReady = false
      var viewed: String?
      var unread = 0
      var actions = ServerWindowActions()
      let onRoute: (DeepLinkRoute) -> Void

      var body: some View {
        Color.clear.serverWindow(
          id, desktop: desktop, isReady: isReady, viewedSessionID: viewed, unreadCount: unread,
          actions: actions, onRoute: onRoute)
      }
    }

    @Test("a window registers itself, reports changes and is forgotten when it closes")
    func registers() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let window = ServerWindowID.newWindow(serverURL: try url("https://a.test"))
      let registry = fixture.desktop.registry
      let content = { (ready: Bool, viewed: String?, unread: Int) in
        Content(
          id: .constant(window), desktop: fixture.desktop, isReady: ready, viewed: viewed,
          unread: unread, onRoute: { _ in })
      }
      let screen = OffscreenWindow(content(false, nil, 0), width: 200, height: 100)
      await flush(screen)
      #expect(registry.entry(window.instance)?.isReady == false)
      screen.host.rootView = content(true, "s1", 3)
      await flush(screen)
      let entry = try #require(registry.entry(window.instance))
      #expect(entry.isReady)
      #expect(entry.viewedSessionID == "s1")
      #expect(entry.unreadCount == 3)
      screen.close()
      screen.settle(0.05)
    }

    @Test("a route waits until the window is ready, then applies once")
    func routes() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let window = ServerWindowID.newWindow(serverURL: try url("https://a.test"))
      fixture.desktop.registry.deliver(.conversation(sessionID: "s1"), to: window.instance)
      var received: [DeepLinkRoute] = []
      let content = { (ready: Bool) in
        Content(
          id: .constant(window), desktop: fixture.desktop, isReady: ready,
          onRoute: { received.append($0) })
      }
      let screen = OffscreenWindow(content(false), width: 200, height: 100)
      defer { screen.close() }
      await flush(screen)
      #expect(received.isEmpty, "not signed in yet")
      screen.host.rootView = content(true)
      await flush(screen)
      #expect(received == [.conversation(sessionID: "s1")])
      #expect(fixture.desktop.registry.pendingRoute(for: window.instance) == nil)
    }

    /// A window's root that passes its selection on without reading it, and counts its renders.
    private struct ShownContent: View {
      let id: ServerWindowID
      let desktop: DesktopController
      let shown: ShownWindow
      @State private var selection: String?

      var body: some View {
        shown.rootRenders += 1
        return Color.clear
          .serverWindow(
            .constant(id), desktop: desktop, selection: $selection,
            status: { viewed in
              ServerWindowStatus(isReady: true, viewedSessionID: viewed, unreadCount: shown.unread)
            },
            onRoute: { _ in }
          )
          .onAppear { shown.select = { selection = $0 } }
      }
    }

    /// What a test changes in a ``ShownContent`` window, and what the window counted.
    @Observable
    final class ShownWindow {
      var unread = 0
      @ObservationIgnored var rootRenders = 0
      @ObservationIgnored var select: (String?) -> Void = { _ in }
    }

    @Test("a session or a badge that changes is reported without rendering the window's root")
    func reportsWithoutTheRoot() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let window = ServerWindowID.newWindow(serverURL: try url("https://a.test"))
      let registry = fixture.desktop.registry
      let shown = ShownWindow()
      let screen = OffscreenWindow(
        ShownContent(id: window, desktop: fixture.desktop, shown: shown), width: 200, height: 100)
      defer { screen.close() }
      await flush(screen)
      let rendersAtRest = shown.rootRenders
      #expect(registry.entry(window.instance)?.viewedSessionID == nil)

      shown.select("s1")
      await flush(screen)
      #expect(registry.entry(window.instance)?.viewedSessionID == "s1")
      shown.unread = 4
      await flush(screen)
      #expect(registry.entry(window.instance)?.unreadCount == 4)
      #expect(shown.rootRenders == rendersAtRest, "the root read neither")
    }

    @Test("the frame autosave name is taken once, and a second window lets it be")
    func frameAutosave() throws {
      let name = "OmnigentTest-\(UUID().uuidString)"
      let first = OffscreenWindow(Color.clear.windowFrameAutosave(name), width: 200, height: 100)
      defer { first.close() }
      #expect(first.window.frameAutosaveName == name)
      let second = OffscreenWindow(Color.clear.windowFrameAutosave(name), width: 200, height: 100)
      defer { second.close() }
      #expect(second.window.frameAutosaveName.isEmpty)
    }

    @Test("the minimum-size wrapper shows and places its content")
    func minimumSize() throws {
      let screen = OffscreenWindow(
        WindowMinimumSize(CGSize(width: 100, height: 50)) { Text(verbatim: "inside") },
        width: 300, height: 200)
      defer { screen.close() }
      #expect(try screen.allText().contains("inside"))
    }

  }

  /// The controller's wiring between the local server, windows and notifications.
  @MainActor
  @Suite("Desktop controller", .serialized)
  struct DesktopControllerTests {
    init() { DesktopSideEffects.reset() }

    @Test("a started server offers a window, and Open Window opens it")
    func offersWindow() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var asked: [URL] = []
      var opened: [ServerWindowID] = []
      fixture.desktop.confirmOpenLocalServer = { endpoint in
        asked.append(endpoint.url)
        return true
      }
      fixture.desktop.router.confirmUnknownServer = { _ in true }
      fixture.desktop.router.attachWindowOpener { opened.append($0) }
      let server = try loopback(6767)
      fixture.local.runner.script(announces(6767))
      fixture.local.probe.answer(server, .ready(nil))
      await fixture.manager.startServer(trigger: .user)
      await waitUntil(within: .seconds(2)) { !opened.isEmpty }
      #expect(asked == [server])
      #expect(opened.map(\.serverURL) == [server])
      await fixture.manager.stopOwnedProcesses()
    }

    @Test("a server that started on its own doesn't ask")
    func launchDoesNotOffer() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var asked = 0
      fixture.desktop.confirmOpenLocalServer = { _ in
        asked += 1
        return true
      }
      let server = try loopback(6767)
      fixture.local.runner.script(announces(6767))
      fixture.local.probe.answer(server, .ready(nil))
      await fixture.manager.startServer(trigger: .launch)
      await Task.yield()
      #expect(fixture.manager.server.endpoint?.url == server)
      #expect(asked == 0)
      await fixture.manager.stopOwnedProcesses()
    }

    @Test("Not Now, and a window already on the server, open nothing")
    func noExtraWindow() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var opened = 0
      fixture.desktop.router.attachWindowOpener { _ in opened += 1 }
      let endpoint = try #require(LocalServerEndpoint(port: 6767, pid: nil, manifest: nil))
      fixture.desktop.confirmOpenLocalServer = { _ in false }
      await fixture.desktop.offerWindow(on: endpoint)
      #expect(opened == 0)

      var asked = 0
      fixture.desktop.confirmOpenLocalServer = { _ in
        asked += 1
        return true
      }
      fixture.desktop.registry.update(
        ServerWindowID.newWindow(serverURL: endpoint.url), isReady: true, viewedSessionID: nil,
        unreadCount: 0)
      await fixture.desktop.offerWindow(on: endpoint)
      #expect(asked == 0, "a window is already there")
    }

    @Test("the ready alert names the server and its first button opens")
    func readyAlert() async throws {
      let endpoint = try #require(LocalServerEndpoint(port: 6767, pid: nil, manifest: nil))
      #expect(await LocalServerReadyAlert.confirm(endpoint))
      #expect(SystemSideEffects.record.alertMessages == ["The local server is ready"])
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      #expect(await !LocalServerReadyAlert.confirm(endpoint))
    }

    @Test("the host alert names the server and defaults to Cancel")
    func hostAlert() async throws {
      let server = try url("https://team.test")
      #expect(await !HostModeConfirmation.confirm(serverURL: server))
      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      #expect(await HostModeConfirmation.confirm(serverURL: server))
      let text = HostModeConfirmation.text(serverURL: server)
      #expect(text.message.contains("team.test"))
      #expect(text.message.contains("Only host for a server you trust."))
    }

    @Test("with a main window the alert becomes its sheet")
    func alertSheet() async throws {
      let alert = NSAlert()
      alert.messageText = "On a window"
      #expect(await DesktopAlert.present(alert) == .alertFirstButtonReturn)
      #expect(SystemSideEffects.record.alertMessages == ["On a window"])
    }

    @Test("the unread total reaches the Dock badge, and clears at zero")
    func dockBadge() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let window = ServerWindowID.newWindow(serverURL: try url("https://a.test"))
      fixture.desktop.registry.update(
        window, isReady: true, viewedSessionID: nil, unreadCount: 4)
      #expect(NSApplication.shared.dockTile.badgeLabel == "4")
      fixture.desktop.registry.remove(window.instance)
      #expect(NSApplication.shared.dockTile.badgeLabel == nil)
    }

    @Test("a tapped notification opens its route through the router")
    func notificationTap() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      var opened: [ServerWindowID] = []
      fixture.desktop.router.confirmUnknownServer = { _ in true }
      fixture.desktop.router.attachWindowOpener { opened.append($0) }
      let server = try url("https://a.test")
      fixture.desktop.notifications.onActivate(
        NotificationActivation(serverURL: server, route: .conversation(sessionID: "s1")))
      await fixture.desktop.router.drainTask?.value
      #expect(opened.map(\.serverURL) == [server])
    }

    @Test("notification choices come from the preferences")
    func notificationPreferences() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.preferences.notifyTurnEnded = false
      fixture.desktop.preferences.soundName = "Tink"
      #expect(!fixture.desktop.notifications.preferencesProvider().turnEnded)
      #expect(fixture.desktop.notifications.soundNameProvider() == "Tink")
      #expect(
        fixture.desktop.notifications.contextProvider().activeServerCount == 0)
    }

    @Test("managed domains list the app's own first, and own-domain builds read only theirs")
    func domains() {
      #expect(
        ManagedPreferences.domains(forBundleIdentifier: "x.y") == ["x.y"]
          + ManagedPreferences.defaultDomains)
      #expect(
        ManagedPreferences.domains(forBundleIdentifier: "x.y", ownDomainOnly: true) == ["x.y"])
      #expect(ManagedPreferences.domains(for: .main) == ManagedPreferences.defaultDomains)
    }

    @Test("an edition inside App Sandbox can't run processes")
    func capability() {
      #expect(LocalServerCapability.detect(environment: [:]) == .available)
      let sandboxed = LocalServerCapability.detect(environment: ["APP_SANDBOX_CONTAINER_ID": "x"])
      #expect(sandboxed == .unavailable(.appSandbox))
      #expect(!sandboxed.isAvailable)
      #expect(LocalServerUnavailableReason.disabled("Policy").explanation == "Policy")
      #expect(LocalServerUnavailableReason.appSandbox.explanation.contains("App Sandbox"))
    }
  }

  /// The app delegate: launch, links and stopping what it started at quit.
  @MainActor
  @Suite("App delegate", .serialized)
  struct AppDelegateTests {
    init() { DesktopSideEffects.reset() }

    @Test("outside an app the notification delegate can't install, and that's reported")
    func willFinish() throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let delegate = OmnigentDesktopAppDelegate(desktop: fixture.desktop)
      delegate.applicationWillFinishLaunching(Notification(name: .init("launch")))
      guard case .notificationFailed = fixture.issues.issues.first else {
        Issue.record("expected a notification issue, got \(fixture.issues.issues)")
        return
      }
    }

    @Test("launch hands over to the local server, and links go to the router")
    func launchAndLinks() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      fixture.desktop.localServerPreferences.startOnLaunch = true
      let server = try loopback(6767)
      fixture.local.runner.script(announces(6767))
      fixture.local.probe.answer(server, .ready(nil))
      let delegate = OmnigentDesktopAppDelegate(desktop: fixture.desktop)
      delegate.applicationDidFinishLaunching(Notification(name: .init("launch")))
      await waitUntil(within: .seconds(2)) { fixture.manager.server.endpoint != nil }
      #expect(fixture.manager.server.endpoint?.url == server)

      var opened: [ServerWindowID] = []
      fixture.desktop.router.confirmUnknownServer = { _ in true }
      fixture.desktop.router.attachWindowOpener { opened.append($0) }
      delegate.application(
        NSApplication.shared, open: [try url("omnigent://open?server=https://a.test")])
      await fixture.desktop.router.drainTask?.value
      #expect(opened.count == 1)
      await fixture.manager.stopOwnedProcesses()
    }

    @Test("quit is immediate with nothing to stop, and waits for a server the app started")
    func quit() async throws {
      let fixture = try DesktopFixture()
      defer { fixture.cleanUp() }
      let delegate = OmnigentDesktopAppDelegate(desktop: fixture.desktop)
      #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
      _ = try await fixture.startServer()
      #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
      await waitUntil(within: .seconds(2)) { !DesktopSideEffects.state.terminationReplies.isEmpty }
      #expect(DesktopSideEffects.state.terminationReplies == [true])
      #expect(fixture.manager.server.endpoint == nil)
    }
  }
#endif
