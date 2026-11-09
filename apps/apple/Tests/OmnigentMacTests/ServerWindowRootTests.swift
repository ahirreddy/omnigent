import OmnigentAppUI
import OmnigentDesktop
import OmnigentStores
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

  private func waitFor(
    _ screen: OffscreenWindow<Host>, _ condition: () -> Bool, seconds: Double = 5
  ) -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition(), Date() < deadline { screen.settle(0.05) }
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

  private func demoScratch() throws -> TestScratch {
    try TestScratch(launchArguments: ["-OmnigentDemo"])
  }

  @Test func aWindowOnTheDemoServerBecomesReady() throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    #expect(waitFor(screen) { registry.entry(binding.id.instance)?.isReady == true })
    #expect(registry.entry(binding.id.instance)?.id.serverURL == demoURL)
  }

  @Test func aLinkToAConversationShowsIt() throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    defer { screen.close() }
    let registry = scratch.desktop.registry
    let instance = binding.id.instance
    #expect(waitFor(screen) { registry.entry(instance)?.isReady == true })

    registry.deliver(.conversation(sessionID: "demo-notes"), to: instance)
    #expect(waitFor(screen) { registry.entry(instance)?.viewedSessionID == "demo-notes" })

    registry.deliver(.message(sessionID: "demo-design", messageID: "m1"), to: instance)
    #expect(waitFor(screen) { registry.entry(instance)?.viewedSessionID == "demo-design" })

    registry.deliver(.home, to: instance)
    #expect(waitFor(screen) { registry.entry(instance)?.viewedSessionID == nil })
  }

  @Test func aWindowWithNoServerShowsTheConnectScreenAndIsNotReady() throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: nil, scratch: scratch)
    defer { screen.close() }
    screen.settle(0.3)
    #expect(scratch.desktop.registry.entry(binding.id.instance)?.isReady == false)
    #expect(binding.id.serverURL == nil)
    #expect(!screen.controlFrames.isEmpty)
  }

  /// Closing a window forgets it, unless the app is quitting.
  @Test func closingTheWindowLeavesTheRegistry() throws {
    let scratch = try demoScratch()
    defer { scratch.remove() }
    let (screen, binding) = open(on: demoURL, scratch: scratch)
    let registry = scratch.desktop.registry
    #expect(waitFor(screen) { registry.entry(binding.id.instance) != nil })
    screen.close()
    screen.settle(0.2)
    #expect(registry.entry(binding.id.instance) == nil)
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
}
