import Foundation
import OmnigentRemoteBrowser
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI

/// What the + menu offers is read when a session shows, without its New Tab page.
@MainActor
@Suite("New tab options", .serialized, .timeLimit(.minutes(1)))
struct NewTabOptionsLoadingTests {
  @Test("A shown session's terminals and remote browser profiles load for the + menu")
  func loadsForTheShownSession() async throws {
    let server = threeSessionServer()
    server.route("/v1/sessions/conv_a/agent", .json(#"{"terminals":["zsh","bash"]}"#))
    let connection = try await signedInStore(server)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let session = ServerSession(
      connection: connection, remoteBrowser: FixtureRemoteBrowser(latency: .milliseconds(1)))
    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: WindowSelection(.session("conv_a"))),
      width: 1200, height: 800)
    defer { screen.close() }
    try await settle(screen, until: "the session's options") {
      session.remoteBrowsers?.profiles["conv_a"] != nil
        && session.declaredTerminalNames(in: "conv_a") == .names(["zsh", "bash"])
    }
    #expect(session.tabs.current?.tabs.map(\.content) == [.chat(sessionID: "conv_a")])
    let window = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    let menu = try #require(window.strip?.actions.newTabMenu)
    #expect(menu().state.terminals == .declared(["zsh", "bash"]))
    #expect(menu().state.remoteBrowserProfiles == ["default", "work"])
  }
}
