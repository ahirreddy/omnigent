import AppKit
import OmnigentAppUI
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentTestSupport
import OmnigentViewTesting
import SwiftUI
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// A real server window whose core talks to fake transports, for what the demo server can't do:
/// fail. Also its inspector, and what it does for Settings and the local host.
@MainActor
@Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
struct ServerWindowFailureTests {
  @Observable
  final class WindowBinding {
    var id: ServerWindowID
    init(_ id: ServerWindowID) { self.id = id }
  }

  /// Holds the inspector toggle the window publishes to the Debug menu.
  final class InspectorToggle {
    var current: CoreDebugToggle?
  }

  /// Reads the toggle as the Debug menu does.
  struct InspectorProbe: View {
    @FocusedValue(\.coreDebug) private var coreDebug
    let toggle: InspectorToggle

    var body: some View {
      Color.clear.onChange(of: coreDebug != nil, initial: true) { toggle.current = coreDebug }
    }
  }

  struct Host: View {
    let binding: WindowBinding
    let services: AppServices
    let toggle: InspectorToggle

    var body: some View {
      ServerWindowRoot(
        id: Binding(get: { binding.id }, set: { binding.id = $0 }), services: services
      )
      .background { InspectorProbe(toggle: toggle) }
    }
  }

  private func waitFor(_ condition: () -> Bool, seconds: Double = 10) async throws -> Bool {
    let deadline = Date(timeIntervalSinceNow: seconds)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
    return condition()
  }

  /// An open window and what it was built over.
  @MainActor
  struct OpenWindow {
    let screen: OffscreenWindow<Host>
    let binding: WindowBinding
    let scratch: TestScratch
    let http: FakeHttpTransport

    func close() {
      screen.close()
      scratch.remove()
    }
  }

  /// A window bound to `url`, over a session whose every request fails.
  private func openFailingWindow(on url: URL) throws -> OpenWindow {
    let http = FakeHttpTransport(failingWith: .Other(message: "refused"))
    let scratch = try TestScratch(
      launchArguments: ["-OmnigentDemo"],
      makeDemoSession: { try FakeServerSession.make(http: http) })
    let binding = WindowBinding(ServerWindowID(serverURL: url))
    let screen = OffscreenWindow(
      Host(binding: binding, services: scratch.services, toggle: InspectorToggle()),
      width: 1200, height: 800)
    return OpenWindow(screen: screen, binding: binding, scratch: scratch, http: http)
  }

  /// A server that can't be reached leaves the window on it, not ready, with the reason logged.
  @Test func aServerThatFailsIsLoggedAndTheWindowStaysOnIt() async throws {
    let url = try #require(URL(string: "https://failing-\(UUID().uuidString).example.com"))
    let window = try openFailingWindow(on: url)
    defer { window.close() }
    #expect(try await AppLog.waitFor("Could not connect to \(url.absoluteString)"))
    #expect(!window.http.requests.isEmpty)
    #expect(window.binding.id.serverURL == url)
    let registry = window.scratch.desktop.registry
    #expect(registry.entry(window.binding.id.instance)?.isReady == false)
    #expect(window.scratch.services.recentServers.urls.isEmpty)
  }

  /// Waking the Mac tries a server that was down again, as a VPN coming back needs.
  @Test func aWakeTriesAFailedServerAgain() async throws {
    let url = try #require(URL(string: "https://waking-\(UUID().uuidString).example.com"))
    let window = try openFailingWindow(on: url)
    defer { window.close() }
    let message = "Could not connect to \(url.absoluteString)"
    #expect(try await AppLog.waitFor(message))
    let failures = try AppLog.messages(containing: message).count
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(try await AppLog.waitFor(message, count: failures + 1))
  }

  /// Debug > Show Core Inspector shows the sheet, and Done closes it.
  @Test func theInspectorOpensFromTheDebugCommandAndDoneClosesIt() async throws {
    let scratch = try TestScratch(launchArguments: ["-OmnigentDemo"])
    defer { scratch.remove() }
    let toggle = InspectorToggle()
    let binding = WindowBinding(ServerWindowID(serverURL: URL(string: ServerSession.demoServerURL)))
    let screen = OffscreenWindow(
      Host(binding: binding, services: scratch.services, toggle: toggle), width: 1200, height: 800)
    defer { screen.close() }
    #expect(try await waitFor { toggle.current != nil }, "the window published no toggle")
    try #require(toggle.current).toggle()
    #expect(try await waitFor { screen.window.attachedSheet != nil }, "no inspector sheet")

    let done = try #require(screen.controlFrames.last)
    try screen.click(CGPoint(x: done.midX, y: done.midY))
    #expect(try await waitFor { screen.window.attachedSheet == nil }, "Done left the sheet up")
  }

  /// A link to Settings opens it on this window's server.
  @Test func aLinkToSettingsOpensItForThisWindow() async throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: nil))
    let root = ServerWindowRoot(
      id: Binding(get: { binding.id }, set: { binding.id = $0 }), services: scratch.services)
    var opened: [SettingsDestination] = []
    let spy = OpenSettingsDestinationAction { opened.append($0) }
    let session = ServerSession(connection: try await PreviewData.connectedDemoStore())
    let server = try #require(session.connection.supervisedServerURL)

    root.apply(.settings(section: "mcp"), in: session, openSettingsAt: spy)
    #expect(opened == [DeepLinkDestinations.settings(section: "mcp", server: server)])

    let openSettings = try #require(root.serverSwitching(session, openSettingsAt: spy).openSettings)
    openSettings()
    #expect(opened.last == .server(url: server, pane: nil))
  }

  /// Open in New Window goes to the router with this window's server; with none, nothing opens.
  @Test func openInNewWindowUsesThisWindowsServer() async throws {
    let scratch = try TestScratch()
    defer { scratch.remove() }
    var opened: [ServerWindowID] = []
    scratch.desktop.router.requestWindow = {}
    scratch.desktop.router.attachWindowOpener { opened.append($0) }
    let url = try #require(URL(string: "https://omnigent.example.com"))
    let binding = WindowBinding(ServerWindowID(serverURL: nil))
    let root = ServerWindowRoot(
      id: Binding(get: { binding.id }, set: { binding.id = $0 }), services: scratch.services)

    root.openNewWindow(on: "session")
    try await Task.sleep(for: .milliseconds(50))
    #expect(opened.isEmpty)

    binding.id = binding.id.rebound(to: url)
    root.openNewWindow(on: "session")
    #expect(try await waitFor { !opened.isEmpty })
    #expect(opened.map(\.serverURL) == [url])
  }

  /// "Use This Mac" only where the edition runs the CLI, and a remote server still asks first.
  @Test func useThisMacAsksBeforeHostingForAnotherServer() async throws {
    let unavailable = try TestScratch()
    defer { unavailable.remove() }
    let noServer = WindowBinding(ServerWindowID(serverURL: nil))
    let noHost = ServerWindowRoot(
      id: Binding(get: { noServer.id }, set: { noServer.id = $0 }), services: unavailable.services)
    #expect(noHost.useThisMachine == nil)

    let scratch = try TestScratch(localServerCapability: .available)
    defer { scratch.remove() }
    let manager = scratch.desktop.localServer
    var asked: [URL] = []
    manager.confirmHostMode = { url in
      await Task.yield()
      asked.append(url)
      return false
    }
    let root = ServerWindowRoot(
      id: Binding(get: { noServer.id }, set: { noServer.id = $0 }), services: scratch.services)
    let action = try #require(root.useThisMachine)
    let url = try #require(URL(string: "https://omnigent.example.com"))

    let status = await action(url)

    #expect(asked == [url])
    #expect(status == manager.host.summary)
    #expect(manager.hostLog.text.contains("was not allowed"))
  }

  /// The sidebar's "this Mac" comes from the CLI's config; one it can't read is reported.
  @Test func thisMacsHostIDComesFromTheCLIConfig() async throws {
    let scratch = try TestScratch(localServerCapability: .available)
    defer { scratch.remove() }
    let binding = WindowBinding(ServerWindowID(serverURL: nil))
    let root = ServerWindowRoot(
      id: Binding(get: { binding.id }, set: { binding.id = $0 }), services: scratch.services)
    let session = try ServerSession.demo()
    root.configure(session)
    let file = scratch.desktop.localServer.cliConfigFile
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)

    let hostID = "0123456789abcdef0123456789abcdef"
    try Data("host:\n  host_id: \(hostID)\n".utf8).write(to: file)
    #expect(session.connection.sessionList.thisMachineHostID() == hostID)

    // A folder where the file belongs fails the read, as a damaged home would.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
    #expect(session.connection.sessionList.thisMachineHostID() == nil)
    #expect(try await AppLog.waitFor("This Mac's host id is unreadable"))
  }
}
