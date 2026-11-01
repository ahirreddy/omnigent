import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// One server window: its own ``ServerSession`` (a core-backed `ConnectionStore` and its
/// sign-in), bound to the server in its `ServerWindowID`.
///
/// The window is ready (deep links navigate in place, notifications are suppressed while it
/// shows a session) only while its core is signed in to exactly the server the window is bound
/// to, so rebinding the window makes it not ready in the same update.
struct ServerWindowRoot: View {
  @Binding var id: ServerWindowID
  let services: AppServices

  @State private var session: ServerSession?
  @State private var selection: SidebarDestination?
  @State private var showsCoreDebug = false
  @Environment(\.openWindow) private var openWindow
  @Environment(\.appearsActive) private var appearsActive

  private var desktop: DesktopController { services.desktop }

  var body: some View {
    Group {
      if let session {
        window(session)
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .omnigentTheme(services.theme.theme, appearance: services.theme.mode)
    .task { start() }
  }

  private func window(_ session: ServerSession) -> some View {
    let isReady = Self.isReady(session, boundTo: id.serverURL)
    let notifications = session.connection.notifications
    return ServerRootView(
      session: session, selection: $selection, isWindowFocused: appearsActive,
      openInNewWindow: { sessionID in openNewWindow(on: sessionID) }
    )
    .navigationTitle(title(session))
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Browser", systemImage: "globe", action: openBrowser)
          .disabled(id.serverURL == nil)
          .help("Open this server in the browser window (Option-Command-B)")
          .accessibilityIdentifier("toolbar.browser")
      }
    }
    .sheet(isPresented: $showsCoreDebug) {
      CoreDebugView()
        .environment(session.connection)
        .frame(minWidth: 720, minHeight: 600)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { showsCoreDebug = false }
          }
        }
    }
    .focusedSceneValue(\.coreDebug, CoreDebugToggle { showsCoreDebug.toggle() })
    .serverWindow(
      $id, desktop: desktop, isReady: isReady,
      viewedSessionID: isReady ? selection?.sessionID : nil,
      unreadCount: isReady ? notifications?.badgeCount ?? 0 : 0,
      actions: actions(session), onRoute: { route in apply(route) }
    )
    .desktopAttention(session.connection, serverURL: id.serverURL, desktop: desktop)
    .menuBarSessions(
      session.connection, serverURL: isReady ? id.serverURL : nil, instance: id.instance,
      in: services.menuBar)
    .windowFrameAutosave()
    .task(id: id.serverURL) { await connectBoundServer(session, force: false) }
    .task { await reconnectOnSystemTriggers(session) }
  }

  /// Creates the window's session once and binds its sign-in to the window.
  private func start() {
    guard session == nil else { return }
    let session = services.makeServerSession()
    session.signIn.directory = services.serverDirectory()
    session.signIn.forgetServer = { [services] url in
      if let url = URL(string: url) { services.recentServers.forget(url) }
      session.signIn.directory = services.serverDirectory()
    }
    session.signIn.onServerChange = { url in
      guard let url else {
        selection = nil
        id = id.rebound(to: nil)
        return
      }
      if !Self.sameServer(id.serverURL, url) { id = id.rebound(to: url) }
      if session.isSignedIn { Task { await services.didConnect(to: url) } }
    }
    self.session = session
  }

  private func title(_ session: ServerSession) -> String {
    if let server = session.connection.connectedServer {
      return server.serverName ?? URL(string: server.baseUrl)?.host(percentEncoded: false)
        ?? "Omnigent"
    }
    return id.serverURL?.host(percentEncoded: false) ?? "Omnigent"
  }

  private func actions(_ session: ServerSession) -> ServerWindowActions {
    let bound = id.serverURL != nil
    let signInActions = session.signIn.actions
    return ServerWindowActions(
      newSession: session.isSignedIn ? { selection = .newSession } : nil,
      changeServer: bound
        ? {
          session.connection.disconnect()
          selection = nil
          id = id.rebound(to: nil)
        } : nil,
      signOut: session.connection.connectedServer?.mode == .localSingleUser || !session.isSignedIn
        ? nil : { signInActions.signOut() },
      reconnect: bound ? { Task { await connectBoundServer(session, force: true) } } : nil)
  }

  private func apply(_ route: OmnigentDesktop.DeepLinkRoute) {
    switch route {
    case .home: selection = nil
    case .conversation(let sessionID): selection = .session(sessionID)
    }
  }

  /// Connects to the window's server when the binding changes, and on Reconnect.
  private func connectBoundServer(_ session: ServerSession, force: Bool) async {
    guard let serverURL = id.serverURL else { return }
    if !force, Self.isConnecting(session, to: serverURL) { return }
    await session.signIn.connectNow(serverURL.absoluteString)
    guard !Task.isCancelled, id.serverURL == serverURL else { return }
    if session.isSignedIn {
      await services.didConnect(to: serverURL)
    } else if case .failed(_, let error) = session.connection.phase {
      services.logger.notice(
        "Could not connect to \(serverURL.absoluteString, privacy: .public): \(error.message, privacy: .public)"
      )
    }
  }

  /// Wake, unlock and session switches reopen the streams, so a server that came back with the
  /// VPN reconnects within seconds.
  private func reconnectOnSystemTriggers(_ session: ServerSession) async {
    let monitor = desktop.makeReconnectMonitor()
    for await trigger in monitor.triggers {
      guard id.serverURL != nil else { continue }
      services.logger.info("Reconnecting after \(String(describing: trigger), privacy: .public)")
      if session.isSignedIn {
        session.connection.foreground()
      } else {
        await connectBoundServer(session, force: true)
      }
    }
    monitor.stop()
  }

  private func openBrowser() {
    guard let serverURL = id.serverURL else { return }
    openWindow(id: BrowserWindow.id, value: serverURL)
  }

  private func openNewWindow(on sessionID: String) {
    guard let serverURL = id.serverURL else { return }
    desktop.router.open(.conversation(sessionID: sessionID), onServer: serverURL)
  }

  /// Whether the core is signed in to the window's server.
  static func isReady(_ session: ServerSession, boundTo serverURL: URL?) -> Bool {
    guard let serverURL, let connected = session.connectedURL else { return false }
    return sameServer(connected, serverURL)
  }

  /// Whether the core is already connected, connecting or signing in to `serverURL`.
  static func isConnecting(_ session: ServerSession, to serverURL: URL) -> Bool {
    let phaseURL: String? =
      switch session.connection.phase {
      case .disconnected, .failed: nil
      case .discovering(let url): url
      case .signInRequired(let url, _, _, _, _), .signingIn(let url),
        .awaitingBrowserLogin(let url, _), .connecting(let url):
        url
      case .connected(let server): server.baseUrl
      }
    return sameServer(phaseURL.flatMap(URL.init(string:)), serverURL)
  }

  /// Two server URLs name the same server, ignoring case and a trailing slash.
  static func sameServer(_ lhs: URL?, _ rhs: URL?) -> Bool {
    func key(_ url: URL?) -> String? {
      guard var text = url?.absoluteString.lowercased() else { return nil }
      while text.hasSuffix("/") { text.removeLast() }
      return text
    }
    guard let left = key(lhs) else { return false }
    return left == key(rhs)
  }
}
