import AppKit
import Foundation
import Observation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// What the host keeps for a window: the page it shows.
@MainActor
@Observable
final class WindowSelection {
  var page: SidebarDestination?

  init(_ page: SidebarDestination? = nil) { self.page = page }

  var binding: Binding<SidebarDestination?> {
    Binding(get: { self.page }, set: { self.page = $0 })
  }
}

/// A window's root over `session`, the way the host mounts it: the page is the root's own
/// state, which its body never reads.
struct AppWindowRoot: View {
  let session: ServerSession
  let selection: WindowSelection
  var tabContext = TabWindowContext()
  var serverSwitching: ServerSwitching?
  var openInNewWindow: (@MainActor (String) -> Void)?
  /// What `@AppStorage` reads in the window. The process's own defaults are one file shared by
  /// every test process on the machine, so a write from any of them renders the views reading it.
  var preferences = UserDefaults.standard
  @State private var page: SidebarDestination?

  init(
    session: ServerSession, selection: WindowSelection,
    tabContext: TabWindowContext = TabWindowContext(), serverSwitching: ServerSwitching? = nil,
    openInNewWindow: (@MainActor (String) -> Void)? = nil,
    preferences: UserDefaults = .standard
  ) {
    self.session = session
    self.selection = selection
    self.tabContext = tabContext
    self.serverSwitching = serverSwitching
    self.openInNewWindow = openInNewWindow
    self.preferences = preferences
    _page = State(initialValue: selection.page)
  }

  var body: some View {
    ServerRootView(
      session: session, selection: $page, openInNewWindow: openInNewWindow,
      tabContext: tabContext, serverSwitching: serverSwitching
    )
    .modifier(HostedSelection(selection: selection, page: $page))
    .defaultAppStorage(preferences)
  }
}

/// Keeps the root's page and the test's ``WindowSelection`` the same, in a body of its own.
private struct HostedSelection: ViewModifier {
  let selection: WindowSelection
  @Binding var page: SidebarDestination?

  func body(content: Content) -> some View {
    content
      .onChange(of: selection.page) { _, chosen in
        if page != chosen { page = chosen }
      }
      .onChange(of: page) { _, shown in
        if selection.page != shown { selection.page = shown }
      }
  }
}

/// The core's offline demo server, connected: sample sessions, with replies on a timer.
@MainActor
func connectedDemo() async throws -> ServerSession {
  SystemSideEffects.install()
  let session = try ServerSession.demo()
  await session.connection.connect(serverURL: ServerSession.demoServerURL)
  #expect(session.isSignedIn, "phase: \(session.connection.phase)")
  try await eventually("the demo's sessions") { session.connection.sessionList.isLoaded }
  return session
}

/// A server with sessions `conv_a`, `conv_b` and `conv_c` on one online host.
nonisolated func threeSessionServer() -> AppServer {
  let server = newSessionServer()
  let ids = ["conv_a", "conv_b", "conv_c"]
  let rows = ids.enumerated().map { index, id in
    sessionRow(id, host: "mac", workspace: "/work/\(id)", updatedAt: Int64(30 - index))
  }
  server.route(
    "/v1/sessions", method: "GET",
    .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
  for (index, id) in ids.enumerated() {
    server.route("/v1/sessions/\(id)", .json(rows[index]))
  }
  return server
}

/// A signed-in session over `server` whose links are only recorded.
@MainActor
func signedInSession(_ server: AppServer) async throws -> ServerSession {
  SystemSideEffects.install()
  let connection = try await signedInStore(server)
  try await eventually("the session list") { connection.sessionList.isLoaded }
  return ServerSession(connection: connection, opener: ExternalURLOpener { _ in true })
}

/// The connected view's actions, as its sidebar calls them, without a window.
@MainActor
func connectedView(
  _ session: ServerSession, _ selection: WindowSelection,
  opener: ExternalURLOpener = ExternalURLOpener { _ in true },
  serverSwitching: ServerSwitching? = nil, openInNewWindow: (@MainActor (String) -> Void)? = nil
) -> ConnectedServerView {
  ConnectedServerView(
    session: session, selection: selection.binding, sidebar: SidebarModel(), opener: opener,
    openInNewWindow: openInNewWindow, serverSwitching: serverSwitching)
}
