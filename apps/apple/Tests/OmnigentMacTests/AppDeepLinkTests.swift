import AppKit
import OmnigentDeepLinks
import OmnigentDesktop
import OmnigentViewTesting
import Testing

#if OMNIGENT_CHROMIUM
  @testable import OmnigentMac
#else
  @testable import OmnigentMacAppStore
#endif

/// An `omnigent://` link from the system to the window it opens, through the app's delegate. The
/// window opener is the test's, so no real window opens.
@MainActor
@Suite(.enabled(if: HostedOffscreen.isAllowed), .serialized)
struct AppDeepLinkTests {
  private final class Opened {
    var windows: [ServerWindowID] = []
    var issues: [DesktopIssue] = []
  }

  private func boundDelegate(_ opened: Opened) -> OmnigentMacAppDelegate {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    let delegate = OmnigentMacAppDelegate()
    delegate.services.bind()
    delegate.desktop.onIssue = { opened.issues.append($0) }
    delegate.desktop.router.attachWindowOpener { opened.windows.append($0) }
    return delegate
  }

  private func settle(until condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() {
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test func aLinkToAKnownServerOpensItsConversation() async throws {
    let opened = Opened()
    let delegate = boundDelegate(opened)
    let server = try #require(URL(string: "https://known.example.com"))
    delegate.services.recentServers.record(server)
    defer { delegate.services.recentServers.forget(server) }

    let link = try #require(URL(string: "omnigent://known.example.com/c/conv_abc"))
    delegate.application(.shared, open: [link])
    try await settle { !opened.windows.isEmpty }

    let window = try #require(opened.windows.first)
    #expect(window.serverURL == server)
    let route = delegate.desktop.registry.pendingRoute(for: window.instance)
    #expect(route == .conversation(sessionID: "conv_abc"))
    #expect(SystemSideEffects.record.alertMessages.isEmpty, "a known server asks nothing")
  }

  @Test func aLinkThatIsNotOursOpensNothing() async throws {
    let opened = Opened()
    let delegate = boundDelegate(opened)
    let link = try #require(URL(string: "https://example.com/c/conv_abc"))
    delegate.application(.shared, open: [link])
    try await Task.sleep(for: .milliseconds(30))
    #expect(opened.windows.isEmpty)
    #expect(opened.issues.count == 1)
  }

  /// A never-used server can show notifications once connected, so it asks first.
  @Test func aLinkToANewServerOpensNothingWhenDeclined() async throws {
    let opened = Opened()
    let delegate = boundDelegate(opened)
    SystemSideEffects.answer(alert: .alertFirstButtonReturn)
    let link = try #require(URL(string: "omnigent://new.example.com/c/conv_abc"))
    delegate.application(.shared, open: [link])
    try await settle { !opened.issues.isEmpty }

    #expect(SystemSideEffects.record.alertMessages == ["Open this Omnigent link?"])
    #expect(opened.windows.isEmpty)
    #expect(delegate.services.recentServers.urls.allSatisfy { $0.host != "new.example.com" })
  }

  @Test func aLinkToANewServerOpensAndIsRememberedWhenAccepted() async throws {
    let opened = Opened()
    let delegate = boundDelegate(opened)
    SystemSideEffects.answer(alert: .alertSecondButtonReturn)
    let server = try #require(URL(string: "https://accepted.example.com"))
    defer { delegate.services.recentServers.forget(server) }
    let link = try #require(URL(string: "omnigent://accepted.example.com/c/conv_abc"))
    delegate.application(.shared, open: [link])
    try await settle { !opened.windows.isEmpty }

    #expect(opened.windows.first?.serverURL?.host == "accepted.example.com")
    #expect(delegate.services.recentServers.urls.contains { $0.host == "accepted.example.com" })
  }
}
