import AppKit
import Foundation
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentServices
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// Flows through the mounted window: starting from its page, splitting, the sidebar's sheets.
@MainActor
@Suite("Connected window flows", .serialized, .timeLimit(.minutes(1)))
struct ConnectedWindowFlowTests {
  struct Mounted {
    let view: ConnectedServerView
    let screen: OffscreenWindow<ConnectedServerView>
    let session: ServerSession
    let selection: WindowSelection
    let model: SidebarModel
  }

  func mounted(
    _ server: AppServer = threeSessionServer(), page: SidebarDestination? = .session("conv_a")
  ) async throws -> Mounted {
    let session = try await signedInSession(server)
    let selection = WindowSelection(page)
    let model = SidebarModel()
    let view = ConnectedServerView(
      session: session, selection: selection.binding, sidebar: model,
      opener: ExternalURLOpener { _ in true }, openInNewWindow: nil, serverSwitching: nil)
    let screen = OffscreenWindow(view, width: 1200, height: 800)
    try await pause(screen, .milliseconds(200))
    return Mounted(view: view, screen: screen, session: session, selection: selection, model: model)
  }

  @Test("A session started on the window's page opens in place of the form")
  func startingOpensTheSession() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_new",
      .json(
        #"{"id":"conv_new","status":"idle","created_at":1,"agent_id":"ag_claude","host_id":"mac","permission_level":4}"#
      ))
    server.route(
      "/v1/sessions/conv_new/events", method: "POST", .json(#"{"queued":false}"#, status: 202))
    let mounted = try await mounted(server, page: .newSession)
    defer { mounted.screen.close() }
    try await settle(mounted.screen, until: "the folder listing") {
      !server.requests("GET", "/v1/hosts/mac/filesystem").isEmpty
    }
    try await pause(mounted.screen, .milliseconds(150))
    let composer = try #require(mounted.screen.allViews.first { $0 is NSTextView })
    try mounted.screen.click(composer)
    try mounted.screen.type("hello")
    try mounted.screen.press(keyCode: 36, characters: "\r")
    try await settle(mounted.screen, until: "the session") {
      mounted.selection.page == .session("conv_new")
    }
  }

  @Test("A split window shows each pane's tab, and closing one goes back to one pane")
  func splitting() async throws {
    let mounted = try await mounted()
    defer { mounted.screen.close() }
    let store = try #require(mounted.session.tabs.current)
    let inbox = store.open(.inbox)
    store.show(inbox.id, in: .trailing)
    try await pause(mounted.screen, .milliseconds(100))
    #expect(store.splitState != nil)
    #expect(try mounted.screen.shows("Inbox"))
    store.close(inbox.id)
    try await pause(mounted.screen)
    #expect(store.splitState == nil)
  }

  @Test("Archiving a session with a worktree asks, then archives it")
  func archivePrompt() async throws {
    SystemSideEffects.install()
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_b", method: "PATCH",
      .json(#"{"id":"conv_b","status":"idle","created_at":1,"archived":true}"#))
    let mounted = try await mounted(server)
    defer { mounted.screen.close() }
    mounted.model.archiveRequest = ArchiveWorktreeRequest(
      sessionIDs: ["conv_b"], worktreeSessionIDs: ["conv_b"])
    try await settle(mounted.screen, until: "the archive") {
      !server.requests("PATCH", "/v1/sessions/conv_b").isEmpty
        || !server.requests("POST", "/v1/sessions/conv_b/archive").isEmpty
    }
  }

  /// One forkable session, the sheet open on it.
  private func forkSheet(_ server: AppServer) async throws -> Mounted {
    let row = sessionRow("conv_a", host: "mac", workspace: "/w", updatedAt: 9)
      .replacingOccurrences(of: "\"host_id\"", with: "\"agent_id\":\"ag_claude\",\"host_id\"")
    server.route(
      "/v1/sessions", method: "GET", .json(#"{"object":"list","data":[\#(row)],"has_more":false}"#))
    let mounted = try await mounted(server)
    mounted.view.beginSidebarFork("conv_a")
    try await settle(mounted.screen, until: "the sheet") {
      mounted.view.sidebarForkPresented.wrappedValue
    }
    try await pause(mounted.screen, .milliseconds(150))
    return mounted
  }

  @Test("A fork refused by the server stays in its sheet")
  func aRefusedFork() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/fork", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
    let mounted = try await forkSheet(server)
    defer { mounted.screen.close() }
    mounted.view.sidebarForkActions.forkWith(
      ForkChoices(agentID: "ag_claude", directory: "/w", start: false, hostID: "mac"))
    try await settle(mounted.screen, until: "the request") {
      !server.requests("POST", "/v1/sessions/conv_a/fork").isEmpty
    }
    try await pause(mounted.screen)
    #expect(mounted.view.sidebarForkPresented.wrappedValue)
  }

  @Test("A fork that was created but didn't start opens it and says so")
  func aForkThatDidNotStart() async throws {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions/conv_a/fork", method: "POST",
      .json(#"{"id":"conv_f","status":"idle","created_at":5,"permission_level":4}"#, status: 201))
    server.route("/v1/hosts/mac/runners", method: "POST", .json(#"{"detail":"no"}"#, status: 500))
    let mounted = try await forkSheet(server)
    defer { mounted.screen.close() }
    mounted.view.sidebarForkActions.forkWith(
      ForkChoices(agentID: "ag_claude", directory: "/w", start: true, hostID: "mac"))
    try await settle(mounted.screen, until: "the failure") {
      mounted.session.connection.sessionList.editError != nil
    }
    #expect(
      mounted.session.connection.sessionList.editError?.message
        .hasPrefix("The fork was created but did not start") == true)
    try await settle(mounted.screen, until: "the fork's chat") {
      mounted.session.tabs.page == .session("conv_f")
    }
  }

  @Test("A window signed in to an account offers Sign Out, which signs out")
  func signingOut() async throws {
    SystemSideEffects.install()
    let server = AppServer()
    server.route("/.well-known/omnigent.json", .json(ManifestFixtures.oidc))
    server.route("/v1/info", .json(#"{"single_user":false,"accounts_enabled":false}"#))
    server.route("/v1/me", .json(#"{"detail":"sign in"}"#, status: 401))
    server.route(
      "/auth/native-token", .json(#"{"token":"session-1","refresh_token":"r1","user_id":"u1"}"#))
    server.route("/v1/sessions", .json(#"{"object":"list","data":[],"has_more":false}"#))
    let connection = ConnectionStore(core: try signInCore(server))
    let session = ServerSession(connection: connection, opener: ExternalURLOpener { _ in true })
    session.signIn.authenticateInSheet = { url, _ throws(WebAuthenticationError) in
      let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
        .first { $0.name == "native_state" }?.value
      guard let answer = URL(string: "ai.omnigent.ios:/oauth/callback?code=c&state=\(state ?? "")")
      else { throw .cancelled }
      server.route("/v1/me", .json(#"{"user_id":"u1"}"#))
      return answer
    }
    await session.signIn.connectNow("http://127.0.0.1:6767")
    session.signIn.actions.startBrowserSignIn(
      .browser(redirectUri: "ai.omnigent.ios:/oauth/callback"))
    try await eventually("signing in") {
      if connection.isSignedIn { return true }
      if case .signInRequired(_, _, _, _, let reason?) = session.signIn.state.phase {
        Issue.record("sign-in refused: \(reason.message)")
        return true
      }
      return false
    }

    let selection = WindowSelection()
    let screen = OffscreenWindow(
      AppWindowRoot(session: session, selection: selection), width: 900, height: 600)
    defer { screen.close() }
    try await pause(screen, .milliseconds(150))
    let signOut = try #require(connectedView(session, selection).sidebarActions.signOut)
    signOut()
    try await settle(screen, until: "the sign-out") { !connection.isSignedIn }
  }

  private func signInCore(_ server: AppServer) throws -> ClientCore {
    try ClientCore(
      http: server.http, streams: FakeEventStreamTransport(), sockets: FakeWebSocketTransport(),
      clock: SystemClock(), scheduler: TestScheduler(sleepScale: 0.01),
      secureStore: InMemorySecureStore(), entropy: FixedEntropySource(),
      config: HostConfig(urlPolicy: .development, oidcRedirect: .none))
  }
}
