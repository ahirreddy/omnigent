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

  /// Saves each session's tabs and each scene's page; `nil` when Application Support is
  /// unavailable.
  static let tabPersistence: TabPersistence? = {
    do {
      // UI tests pass `-OmnigentTabsDirectory <path>` to start without saved tabs.
      if let directory = UserDefaults.standard.string(forKey: "OmnigentTabsDirectory") {
        return TabPersistence(directory: URL(filePath: directory))
      }
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
  /// The server the launch is reconnecting to, until that connect returns: links to it wait
  /// for it, links to another server supersede it.
  @State private var restoringServer: URL?
  /// The launch is reconnecting to the last server and the core has not reported progress yet.
  @State private var isRestoring = false
  /// The scene has been on screen, so leaving the background later is a return.
  @State private var hasBeenActive = false
  @State private var serverCommandRelay = FocusedActionsRelay<ServerCommandActions>()
  /// The scene's stable id, so iPad windows each restore their own page.
  @SceneStorage("omnigent.tabs.window") private var windowID = ""
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openWindow) private var openWindow
  @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows

  var body: some View {
    Group {
      // Until a launch reconnect reports progress, the server list would flash before the app.
      if let session, !(isRestoring && session.signIn.state.phase == .disconnected) {
        // Read state marks a session seen only while the scene is on screen.
        ServerRootView(
          session: session, selection: $selection, isWindowFocused: scenePhase == .active,
          openInNewWindow: openInNewWindow(session),
          tabContext: TabWindowContext(
            window: UUID(uuidString: windowID) ?? UUID(), persistence: Self.tabPersistence,
            browser: IOSBrowser.tabs),
          serverSwitching: serverSwitching(session))
      } else {
        ProgressView()
      }
    }
    .shortWindowsStayCompact()
    .task { await start() }
    .onChange(of: scenePhase, initial: true) { previous, phase in
      // Back from the background: streams reopen and reconcile. A launch, even one that starts
      // in the background to open a link, is not a return; the first connect opens the streams.
      if SceneReturn.isReturn(from: previous, to: phase, hasBeenActive: hasBeenActive),
        session?.isSignedIn == true
      {
        session?.connection.foreground()
      }
      if phase == .active, !hasBeenActive { hasBeenActive = true }
      // iOS may end a backgrounded app without notice: save the tabs and drafts now.
      if phase == .background, previous != .background {
        Self.tabPersistence?.flush()
        ComposerDraftArchive.shared?.flush()
        saveUnsavedFiles()
      }
    }
    // Inside the supervision, so settings links reach its Settings screen.
    .phoneDeepLinks(
      session: session, restoringServer: restoringServer, selection: $selection,
      knownServers: knownServers, switchServer: { switchServer(to: $0) },
      launchLink: request == nil ? Self.launchLink : nil
    )
    .phoneSupervision(
      PhoneAppDelegate.supervision, session: session, selection: $selection,
      scenePhase: scenePhase
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

  /// iOS may end a backgrounded app: saves the scene's unsaved file edits, asking for the time
  /// the saves need.
  private func saveUnsavedFiles() {
    guard let session, !session.unsavedFilePaths.isEmpty else { return }
    let application = UIApplication.shared
    let task = application.beginBackgroundTask(withName: "Save unsaved files")
    Task {
      await session.saveUnsavedFiles()
      if task != .invalid { application.endBackgroundTask(task) }
    }
  }

  private func start() async {
    guard session == nil else { return }
    let isNewWindow = UUID(uuidString: windowID) == nil
    if isNewWindow {
      windowID = (request?.window ?? UUID()).uuidString
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
      // An empty value (`-omnigent.lastServer ""` at launch) means none.
      : request?.serverURL
        ?? defaults.string(forKey: Self.lastServerKey).flatMap {
          $0.isEmpty ? nil : $0
        }
    // Chosen before connecting: the connected app opens with it, however late the core
    // reports the sign-in.
    if isNewWindow, let sessionID = request?.sessionID { selection = .session(sessionID) }
    if let server {
      isRestoring = true
      restoringServer = URL(string: server)
      await session.signIn.connectNow(server)
      isRestoring = false
      restoringServer = nil
    }
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
    if session.isSignedIn {
      let selection = $selection
      actions.newSession = { selection.wrappedValue = .newSession }
    }
    if supportsMultipleWindows {
      let openWindow = openWindow
      let server = session.connectedURL?.absoluteString
      actions.newWindow = { openWindow(value: PhoneWindowRequest(serverURL: server)) }
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
}
