import OSLog
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentCoreFFI
import OmnigentPlatform
import OmnigentStores
import OmnigentUIComponents
import SwiftUI

/// The iPhone and iPad root: the same assembly as the Mac windows, one per scene. The split view
/// collapses to a stack on compact width. The last server is reconnected on launch; an iPad
/// window opened with a ``PhoneWindowRequest`` connects to its server instead.
struct IOSRootView: View {
  static let lastServerKey = "omnigent.lastServer"
  static let recentServersKey = "omnigent.recentServers"

  /// Saves each scene's tabs; `nil` when Application Support is unavailable.
  static let tabPersistence: TabPersistence? = {
    do {
      return try TabPersistence.applicationSupport(
        bundleID: Bundle.main.bundleIdentifier ?? "ai.omnigent.ios")
    } catch {
      Logger(subsystem: "ai.omnigent.ios", category: "app").error(
        "Tabs will not be saved: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }()

  /// What opened this window; `nil` for the first window and those the system opens.
  let request: PhoneWindowRequest?

  @State private var session: ServerSession?
  @State private var selection: SidebarDestination?
  /// The launch connect finished, so links route against the scene's real connection.
  @State private var hasStarted = false
  /// Tabs torn off from another window into this one.
  @State private var adopting: [AppTab] = []
  @State private var serverCommandRelay = FocusedActionsRelay<ServerCommandActions>()
  /// The scene's stable id, so iPad windows each restore their own tabs.
  @SceneStorage("omnigent.tabs.window") private var windowID = ""
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

  var body: some View {
    Group {
      if let session {
        // Read state marks a session seen only while the scene is on screen.
        ServerRootView(
          session: session, selection: $selection, isWindowFocused: scenePhase == .active,
          openInNewWindow: openInNewWindow(session),
          tabContext: TabWindowContext(
            window: UUID(uuidString: windowID) ?? UUID(), persistence: Self.tabPersistence,
            browser: IOSBrowser.tabs,
            moveToNewWindow: moveToNewWindow(session), adopting: adopting),
          serverSwitching: serverSwitching(session))
      } else {
        ProgressView()
      }
    }
    .task { await start() }
    .onChange(of: scenePhase) { previous, phase in
      // Back from the background: streams reopen and reconcile. Launch (inactive to active)
      // is not a return; the first connect opens the streams.
      if previous == .background, phase != .background, session?.isSignedIn == true {
        session?.connection.foreground()
      }
      // iOS may end a backgrounded app without notice: save the tabs now.
      if phase == .background { Self.tabPersistence?.flush() }
    }
    .phoneSupervision(
      PhoneAppDelegate.supervision, session: session, selection: $selection,
      scenePhase: scenePhase
    )
    .phoneDeepLinks(
      session: hasStarted ? session : nil, selection: $selection, knownServers: knownServers,
      switchServer: { switchServer(to: $0) }, launchLink: request == nil ? Self.launchLink : nil
    )
    .focusedSceneValue(\.serverCommands, serverCommandRelay.publish(session.map(serverCommands)))
    #if DEBUG
      // Measurement hooks (docs/performance.md): a session as its deep link opens it (without
      // the system's "Open in" prompt), New Session, and back to the session list.
      .perfHooks(["open", "newsession", "list"]) { hook in
        switch hook {
        case "open": if let id = PerfDriver.requestedSession() { selection = .session(id) }
        case "list": selection = nil
        default: selection = .newSession
        }
      }
    #endif
  }

  private func start() async {
    guard session == nil else { return }
    let isNewWindow = UUID(uuidString: windowID) == nil
    if isNewWindow {
      windowID = (request?.window ?? UUID()).uuidString
      adopting = request?.tabs ?? []
    }
    let session: ServerSession
    if ProcessInfo.processInfo.arguments.contains("-OmnigentDemo") {
      do {
        session = try ServerSession.demo()
      } catch {
        Logger(subsystem: "ai.omnigent.ios", category: "app").error(
          "The demo server did not load: \(String(describing: error), privacy: .public)")
        session = ServerSession.live(keychain: KeychainModeSelection.current())
      }
    } else {
      session = ServerSession.live(keychain: KeychainModeSelection.current())
    }
    bindRecents(session)
    self.session = session
    let defaults = UserDefaults.standard
    // The demo always opens to its own sessions, whatever server the device last used.
    let server =
      session.isDemo
      ? ServerSession.demoServerURL
      : request?.serverURL ?? defaults.string(forKey: Self.lastServerKey)
    // Chosen before connecting: the connected app opens with it, however late the core
    // reports the sign-in.
    if isNewWindow, let sessionID = request?.sessionID { selection = .session(sessionID) }
    if let server { await session.signIn.connectNow(server) }
    hasStarted = true
    #if DEBUG
      if request == nil { runLaunchChecks(session) }
    #endif
  }

  /// Debug builds launched with `-OmnigentOpenURL <link>` open the link as the system would,
  /// without its "Open in" prompt, for simulator checks.
  private static var launchLink: URL? {
    #if DEBUG
      UserDefaults.standard.string(forKey: "OmnigentOpenURL").flatMap(URL.init(string:))
    #else
      nil
    #endif
  }

  #if DEBUG
    /// Debug builds launched with `-OmnigentOpenWindow <session>` open the session in a new iPad
    /// window, for simulator checks.
    private func runLaunchChecks(_ session: ServerSession) {
      if let sessionID = UserDefaults.standard.string(forKey: "OmnigentOpenWindow") {
        openInNewWindow(session)?(sessionID)
      }
    }
  #endif

  /// Keeps the recent servers (the sign-in list and the sidebar's switcher) and the server the
  /// next launch reconnects to.
  private func bindRecents(_ session: ServerSession) {
    let defaults = UserDefaults.standard
    session.signIn.directory = ServerDirectory(
      recentServers: defaults.stringArray(forKey: Self.recentServersKey) ?? [])
    session.signIn.onServerChange = { url in
      guard let url else {
        defaults.removeObject(forKey: Self.lastServerKey)
        selection = nil
        return
      }
      defaults.set(url.absoluteString, forKey: Self.lastServerKey)
      var recents = defaults.stringArray(forKey: Self.recentServersKey) ?? []
      recents.removeAll { $0 == url.absoluteString }
      recents.insert(url.absoluteString, at: 0)
      defaults.set(Array(recents.prefix(10)), forKey: Self.recentServersKey)
      session.signIn.directory = ServerDirectory(recentServers: recents)
    }
    session.signIn.forgetServer = { url in
      var recents = defaults.stringArray(forKey: Self.recentServersKey) ?? []
      recents.removeAll { $0 == url }
      defaults.set(recents, forKey: Self.recentServersKey)
      session.signIn.directory = ServerDirectory(recentServers: recents)
    }
  }
}

// MARK: Servers and windows

extension IOSRootView {
  /// The servers the user connected to, most recent first: the sidebar's switcher and the
  /// servers deep links open without asking.
  var knownServers: [URL] {
    session?.signIn.directory.recentServers.compactMap(URL.init(string:)) ?? []
  }

  /// The sidebar's server menu: recents, Connect to New Server (the server list, where a recent
  /// server can also be forgotten) and, with accounts, Sign Out.
  func serverSwitching(_ session: ServerSession) -> ServerSwitching {
    ServerSwitching(
      servers: knownServers, switchTo: { switchServer(to: $0) }, addServer: { changeServer() })
  }

  /// Moves this scene to `url`, unless it is already signed in there.
  func switchServer(to url: URL) {
    guard let session else { return }
    if session.isSignedIn, ServerSession.sameServer(session.connectedURL, url) { return }
    session.connection.disconnect()
    selection = nil
    session.signIn.connect(url.absoluteString)
  }

  /// Leaves the server for the server list, which the next launch shows too.
  func changeServer() {
    guard let session else { return }
    session.connection.disconnect()
    selection = nil
    UserDefaults.standard.removeObject(forKey: Self.lastServerKey)
  }

  /// The hardware-keyboard menus' Reconnect, Change Server and Sign Out.
  func serverCommands(_ session: ServerSession) -> ServerCommandActions {
    var actions = ServerCommandActions()
    var failedServer: String?
    if case .failed(let serverURL, _) = session.connection.phase { failedServer = serverURL }
    if let server = session.connectedURL?.absoluteString ?? failedServer {
      actions.reconnect = { Task { await session.signIn.connectNow(server) } }
    }
    if session.targetURL != nil || failedServer != nil {
      actions.changeServer = { changeServer() }
    }
    if case .connected(server: let account) = session.signIn.state.phase, account.canSignOut {
      let signIn = session.signIn.actions
      actions.signOut = { signIn.signOut() }
    }
    return actions
  }

  /// iPad's Open in New Window: a window on this server showing the session. `nil` on iPhone.
  func openInNewWindow(_ session: ServerSession) -> (@MainActor (String) -> Void)? {
    guard supportsMultipleWindows else { return nil }
    let openWindow = openWindow
    return { sessionID in
      openWindow(
        value: PhoneWindowRequest(
          serverURL: session.connectedURL?.absoluteString, sessionID: sessionID))
    }
  }

  /// iPad's Move Tab to New Window. `nil` on iPhone.
  func moveToNewWindow(_ session: ServerSession) -> (@MainActor ([AppTab]) -> Void)? {
    guard supportsMultipleWindows else { return nil }
    let openWindow = openWindow
    return { tabs in
      openWindow(
        value: PhoneWindowRequest(serverURL: session.connectedURL?.absoluteString, tabs: tabs))
    }
  }
}
