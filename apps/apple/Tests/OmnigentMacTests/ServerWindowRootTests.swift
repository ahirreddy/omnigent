import AppKit
import OmnigentAppBrowser
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A real server window on the core's offline demo server: no network, no user data.
@MainActor
@Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
struct ServerWindowRootTests {
  /// Holds the window's binding, so a test sees the window rebind.
  @Observable
  final class WindowBinding {
    var id: ServerWindowID
    init(_ id: ServerWindowID) { self.id = id }
  }

  struct Host: View {
    let binding: WindowBinding
    let services: AppServices

    var body: some View {
      ServerWindowRoot(
        id: Binding(get: { binding.id }, set: { binding.id = $0 }), services: services)
    }
  }

  private let demoURL = URL(string: ServerSession.demoServerURL)

  /// Awaits rather than spinning the run loop: a test on the main actor must give it up for
  /// the window's tasks to run in the hosted process.
  private func waitFor(
    _ condition: () -> Bool, seconds: Double = 10
  ) async throws -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    return condition()
  }

  private func open(on url: URL?, scratch: TestScratch) -> (
    OffscreenWindow<Host>, WindowBinding
  ) {
    let binding = WindowBinding(ServerWindowID(serverURL: url))
    let screen = OffscreenWindow(
      Host(binding: binding, services: scratch.services), width: 1200, height: 800)
    return (screen, binding)
  }

  /// What a failed route wait reports: whether the route was taken and what the window shows.
  private func state(of instance: UUID, in registry: ServerWindowRegistry) -> Comment {
    let pending = registry.pendingRoute(for: instance)
    return
      "entry \(String(describing: registry.entry(instance))), pending \(String(describing: pending))"
  }

  private func demoScratch() throws -> TestScratch {
    try TestScratch(launchArguments: ["-OmnigentDemo"])
  }

  @Test func aWindowOnTheDemoServerBecomesReady() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    #expect(try await waitFor { registry.entry(binding.id.instance)?.isReady == true })
    #expect(registry.entry(binding.id.instance)?.id.serverURL == demoURL)
  }

  @Test func aLinkToAConversationShowsIt() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    let instance = binding.id.instance
    #expect(try await waitFor { registry.entry(instance)?.isReady == true })

    registry.deliver(.conversation(sessionID: "demo-notes"), to: instance)
    #expect(try await waitFor { registry.entry(instance)?.viewedSessionID == "demo-notes" })

    registry.deliver(.message(sessionID: "demo-design", messageID: "m1"), to: instance)
    #expect(
      try await waitFor { registry.entry(instance)?.viewedSessionID == "demo-design" },
      state(of: instance, in: registry)
    )

    registry.deliver(.home, to: instance)
    #expect(
      try await waitFor { registry.entry(instance)?.viewedSessionID == nil },
      state(of: instance, in: registry)
    )
  }

  @Test func aWindowWithNoServerShowsTheConnectScreenAndIsNotReady() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: nil, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    #expect(try await waitFor { registry.entry(binding.id.instance) != nil })
    #expect(registry.entry(binding.id.instance)?.isReady == false)
    #expect(binding.id.serverURL == nil)
    #expect(!screen.controlFrames.isEmpty)
  }

  /// Closing a window forgets it, unless the app is quitting.
  @Test func closingTheWindowLeavesTheRegistry() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    let registry = scratch.desktop.registry
    #expect(try await waitFor { registry.entry(binding.id.instance) != nil })
    screen.close()
    #expect(try await waitFor { registry.entry(binding.id.instance) == nil })
  }

  @Test func theTitleNamesTheServerNeverItsAddress() throws {
    let session = try ServerSession.demo()
    #expect(ServerWindowRoot.title(session, boundTo: nil) == "Omnigent")
    #expect(ServerWindowRoot.title(session, boundTo: demoURL) == "This Mac")
    #expect(
      ServerWindowRoot.title(session, boundTo: URL(string: "https://omnigent.example.com"))
        .contains("omnigent.example.com"))
  }

  @Test func readinessFollowsTheBoundServerOnly() async throws {
    let store = try await PreviewData.connectedDemoStore()
    let session = ServerSession(connection: store)
    #expect(ServerWindowRoot.isReady(session, boundTo: demoURL))
    #expect(!ServerWindowRoot.isReady(session, boundTo: nil))
    #expect(!ServerWindowRoot.isReady(session, boundTo: URL(string: "https://other.example.com")))
    #expect(
      try !ServerWindowRoot.isConnecting(
        session, to: #require(URL(string: "https://other.example.com"))))
    #expect(ServerWindowRoot.sameServer(demoURL, URL(string: ServerSession.demoServerURL + "/")))
    #expect(!ServerWindowRoot.sameServer(nil, demoURL))
  }

  @Test func signingInRecordsTheServer() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, _) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let recents = scratch.services.recentServers
    #expect(try await waitFor { !recents.urls.isEmpty })
    #expect(
      recents.urls.map(\.absoluteString).first?.hasPrefix(ServerSession.demoServerURL) == true)
  }

  @Test func aWindowBackOnTheConnectScreenIsNotReady() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    let instance = binding.id.instance
    #expect(try await waitFor { registry.entry(instance)?.isReady == true })
    binding.id = binding.id.rebound(to: nil)
    #expect(try await waitFor { registry.entry(instance)?.isReady == false })
  }

  /// Waking the Mac reopens a signed-in window's streams and leaves it on its server.
  @Test func aWakeKeepsASignedInWindowReady() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    let instance = binding.id.instance
    #expect(try await waitFor { registry.entry(instance)?.isReady == true })
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    try await Task.sleep(for: .milliseconds(100))
    #expect(registry.entry(instance)?.isReady == true)
    #expect(binding.id.serverURL == demoURL)
  }

  @Test func anInviteLinkKeepsTheWindowOnItsServer() async throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    let instance = binding.id.instance
    #expect(try await waitFor { registry.entry(instance)?.isReady == true })
    registry.deliver(.register(invite: "code"), to: instance)
    #expect(try await waitFor { registry.pendingRoute(for: instance) == nil })
    #expect(binding.id.serverURL == demoURL)
  }
}

/// A window's actions and sign-in callbacks, called directly with the session they act on.
@MainActor
struct ServerWindowActionsTests {
  @Observable
  final class WindowBinding {
    var id: ServerWindowID
    init(_ id: ServerWindowID) { self.id = id }
  }

  private let demoURL = URL(string: ServerSession.demoServerURL)
  private let otherURL = URL(string: "https://other.example.com")

  private func root(_ binding: WindowBinding, _ scratch: TestScratch) -> ServerWindowRoot {
    ServerWindowRoot(
      id: Binding(get: { binding.id }, set: { binding.id = $0 }), services: scratch.services)
  }

  @Test func anUnboundWindowHasNoServerActions() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: nil))
    let actions = root(binding, scratch).actions(try ServerSession.demo())
    #expect(actions.newSession == nil)
    #expect(actions.changeServer == nil)
    #expect(actions.reconnect == nil)
    #expect(actions.signOut == nil)
    #expect(actions.find == nil)
    #expect(actions.zoom == nil)
  }

  @Test func changeServerGoesBackToTheConnectScreen() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: demoURL))
    let instance = binding.id.instance
    let session = try ServerSession.demo()
    let changeServer = try #require(root(binding, scratch).actions(session).changeServer)
    changeServer()
    #expect(binding.id.serverURL == nil)
    #expect(binding.id.instance == instance, "the window lost its identity")
  }

  @Test func aSignedInWindowOffersNewSession() async throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: demoURL))
    let session = ServerSession(connection: try await PreviewData.connectedDemoStore())
    let actions = root(binding, scratch).actions(session)
    #expect(actions.newSession != nil)
    #expect(actions.reconnect != nil)
  }

  @Test func switchingServersRebindsOnlyOnAChange() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: demoURL))
    let session = try ServerSession.demo()
    let switching = root(binding, scratch).serverSwitching(
      session, openSettingsAt: OpenSettingsDestinationAction { _ in })
    let same = try #require(URL(string: ServerSession.demoServerURL + "/"))
    let other = try #require(otherURL)

    switching.switchTo(same)
    #expect(binding.id.serverURL == demoURL)
    switching.switchTo(other)
    #expect(binding.id.serverURL == other)
    switching.addServer()
    #expect(binding.id.serverURL == nil)
  }

  @Test func theSwitcherListsKnownServers() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let other = try #require(otherURL)
    scratch.services.recentServers.record(other)
    let binding = WindowBinding(ServerWindowID(serverURL: nil))
    let switching = root(binding, scratch).serverSwitching(
      try ServerSession.demo(), openSettingsAt: OpenSettingsDestinationAction { _ in })
    #expect(switching.servers == [other])
    #expect(switching.organizationServers.isEmpty)
  }

  @Test func signInFollowsTheWindow() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: demoURL))
    let session = try ServerSession.demo()
    root(binding, scratch).configure(session)
    let other = try #require(otherURL)

    session.signIn.onServerChange(other)
    #expect(binding.id.serverURL == other)
    let instanceAfterChange = binding.id
    session.signIn.onServerChange(other)
    #expect(binding.id == instanceAfterChange)
    session.signIn.onServerChange(nil)
    #expect(binding.id.serverURL == nil)
  }

  /// A server that reports an address this can't read is logged, not recorded.
  @Test func aSignInWithAnUnreadableAddressRecordsNothing() async throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let session = ServerSession(connection: try await PreviewData.connectedDemoStore())
    root(WindowBinding(ServerWindowID(serverURL: nil)), scratch).configure(session)
    let connected = try #require(session.connection.connectedServer)
    var unreadable = connected
    unreadable.baseUrl = ""
    session.signIn.onSignedIn(unreadable)
    try await Task.sleep(for: .milliseconds(50))
    #expect(scratch.services.recentServers.urls.isEmpty)
  }

  /// Edit > Find and View > Zoom act on the selected browser tab, and only then.
  @Test func findAndZoomFollowTheSelectedBrowserTab() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let session = try ServerSession.demo()
    let window = root(WindowBinding(ServerWindowID(serverURL: demoURL)), scratch)
    #expect(window.actions(session).zoom == nil)
    let url = try #require(URL(string: "https://example.com"))
    let pageID = scratch.services.browserTabs.makePage(url: url).id
    let page = try #require(scratch.services.browserTabs.page(pageID))
    session.tabs.show(.session("session"))
    session.tabs.open(.browser(browserID: pageID))

    let actions = window.actions(session)
    let zoom = try #require(actions.zoom)
    zoom.zoomIn()
    #expect(page.zoomFactor > 1)
    zoom.zoomOut()
    zoom.zoomOut()
    #expect(page.zoomFactor < 1)
    zoom.reset()
    #expect(page.zoomFactor == 1)
    let find = try #require(actions.find)
    #expect(!page.find.isVisible)
    find.show()
    #expect(page.find.isVisible)
    find.next()
    find.previous()
    #expect(try scratch.services.browserTabs.close(pageID) != nil)
  }

  @Test func forgettingAServerUpdatesThePicker() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let other = try #require(otherURL)
    scratch.services.recentServers.record(other)
    let session = try ServerSession.demo()
    root(WindowBinding(ServerWindowID(serverURL: nil)), scratch).configure(session)
    #expect(session.signIn.directory.recentServers == [other.absoluteString])

    session.signIn.forgetServer(other.absoluteString)
    #expect(scratch.services.recentServers.urls.isEmpty)
    #expect(session.signIn.directory.recentServers.isEmpty)
  }

  /// With no CLI config in the private home, this Mac simply has no host id yet.
  @Test func thisMacHasNoHostIDWithoutACLIConfig() throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let session = try ServerSession.demo()
    root(WindowBinding(ServerWindowID(serverURL: nil)), scratch).configure(session)
    #expect(session.connection.sessionList.thisMachineHostID() == nil)
  }
}
