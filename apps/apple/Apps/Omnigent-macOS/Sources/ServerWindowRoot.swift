import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
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
  /// Tabs torn off from another window into this one.
  @State private var adopting: [AppTab] = []
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
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
    .appearanceSettings(services.theme)
    .omnigentTheme(services.theme.theme, appearance: services.theme.mode)
    .task { start() }
  }

  /// "Use This Mac" in Connect a Host: hosts for the server where the edition runs the CLI.
  private var useThisMachine: UseThisMachineAction? {
    let server = desktop.localServer
    guard server.capability.isAvailable else { return nil }
    return UseThisMachineAction { url in
      await server.startHost(serverURL: url)
      return server.host.summary
    }
  }

  private func window(_ session: ServerSession) -> some View {
    let isReady = Self.isReady(session, boundTo: id.serverURL)
    let notifications = session.connection.notifications
    return ServerRootView(
      session: session, selection: $selection, isWindowFocused: appearsActive,
      openInNewWindow: { sessionID in openNewWindow(on: sessionID) },
      tabContext: TabWindowContext(
        window: id.instance, persistence: services.tabPersistence, browser: services.browserTabs,
        moveToNewWindow: { tabs in moveToNewWindow(tabs) }, adopting: adopting),
      serverSwitching: serverSwitching(session)
    )
    .environment(\.useThisMachine, useThisMachine)
    .navigationTitle(title(session))
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
      in: services.menuBar
    )
    .windowFrameAutosave()
    .onDisappear { services.windowClosed(id.instance) }
    .task(id: id.serverURL) { await connectBoundServer(session, force: false) }
    .onChange(of: id.serverURL) { _, url in
      // Back on the server list: show the servers connected to since the window opened.
      if url == nil { session.signIn.directory = services.serverDirectory() }
    }
    .task { await reconnectOnSystemTriggers(session) }
  }

  /// Creates the window's session once and binds its sign-in to the window.
  private func start() {
    guard session == nil else { return }
    adopting = services.takeHandoff(for: id.instance)
    let session = services.makeServerSession()
    session.signIn.directory = services.serverDirectory()
    session.signIn.localSetup = LocalServerSetup(
      manager: desktop.localServer, showLogs: { openWindow(id: LocalServerLogsWindow.id) })
    session.connection.sessionList.thisMachineHostID = { [services, server = desktop.localServer] in
      do {
        return try server.cliConfigText().flatMap { hostIdFromCliConfig(configYaml: $0) }
      } catch {
        services.logger.error(
          "This Mac's host id is unreadable: \(error.localizedDescription, privacy: .public)")
        return nil
      }
    }
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
    }
    session.signIn.onSignedIn = { server in
      guard let url = URL(string: server.baseUrl) else {
        services.logger.error(
          "Signed in to an unparseable server URL: \(server.baseUrl, privacy: .public)")
        return
      }
      Task { await services.didConnect(to: url) }
    }
    self.session = session
  }

  /// The server's display name ("This Mac" for a loopback server, never `127.0.0.1`).
  private func title(_ session: ServerSession) -> String {
    if let server = session.connection.connectedServer {
      return ExecutionContext.serverDisplayName(name: server.serverName, baseURL: server.baseUrl)
    }
    guard let url = id.serverURL else { return "Omnigent" }
    return ExecutionContext.serverDisplayName(name: nil, baseURL: url.absoluteString)
  }

  /// The sidebar's server switcher: known servers, switching this window in place, connecting
  /// another server (the server picker) and Settings.
  private func serverSwitching(_ session: ServerSession) -> ServerSwitching {
    ServerSwitching(
      servers: services.knownServers(),
      switchTo: { url in
        guard !Self.sameServer(id.serverURL, url) else { return }
        session.connection.disconnect()
        selection = nil
        id = id.rebound(to: url)
      },
      addServer: {
        session.connection.disconnect()
        selection = nil
        id = id.rebound(to: nil)
      },
      openSettings: { openSettings() })
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
      reconnect: bound ? { Task { await connectBoundServer(session, force: true) } } : nil,
      find: browserPage(session).map(Self.find), zoom: browserPage(session).map(Self.zoom))
  }

  /// The selected tab's page, when it is a browser tab: Edit > Find and View > Zoom act on it.
  private func browserPage(_ session: ServerSession) -> BrowserTabModel? {
    guard case .browser(let pageID) = session.tabs.selected?.content else { return nil }
    return services.browserTabs.page(pageID)
  }

  private static func find(_ page: BrowserTabModel) -> ServerWindowActions.Find {
    ServerWindowActions.Find(
      show: { page.showFindBar() },
      next: { Task { await page.findNext(forward: true) } },
      previous: { Task { await page.findNext(forward: false) } })
  }

  private static func zoom(_ page: BrowserTabModel) -> ServerWindowActions.Zoom {
    ServerWindowActions.Zoom(
      reset: { page.resetZoom() }, zoomIn: { page.zoomIn() }, zoomOut: { page.zoomOut() })
  }

  private func apply(_ route: OmnigentDesktop.DeepLinkRoute) {
    switch route {
    case .home: selection = nil
    case .conversation(let sessionID): selection = .session(sessionID)
    case .register(let invite):
      guard let session, let serverURL = id.serverURL,
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
      else { return }
      while components.path.hasSuffix("/") { components.path.removeLast() }
      components.path += "/register"
      components.queryItems = [URLQueryItem(name: "invite", value: invite)]
      if let link = components.string { session.signIn.openInvite(link) }
    }
  }

  /// Connects to the window's server when the binding changes, and on Reconnect.
  private func connectBoundServer(_ session: ServerSession, force: Bool) async {
    guard let serverURL = id.serverURL else { return }
    if !force, Self.isConnecting(session, to: serverURL) { return }
    await session.signIn.connectNow(serverURL.absoluteString)
    guard !Task.isCancelled, id.serverURL == serverURL else { return }
    // A signed-in outcome reaches `didConnect` through `signIn.onSignedIn`.
    if case .failed(_, let error) = session.connection.phase {
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

  /// Tear-off: a new window on this server that adopts `tabs`.
  private func moveToNewWindow(_ tabs: [AppTab]) {
    let window = ServerWindowID.newWindow(serverURL: id.serverURL)
    services.handOff(tabs, to: window.instance)
    openWindow(value: window)
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
