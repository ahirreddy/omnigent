import Foundation
import OSLog
import Observation
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents

/// App-wide services shared by every window: the desktop shell, recent servers, the browser
/// engines, appearance, the menu bar's sessions, the Keychain choice and the log.
@Observable
final class AppServices {
  /// The desktop shell services, owned by the app delegate.
  let desktop: DesktopController
  /// The app log. Every shell issue lands here.
  let logger: Logger
  /// Servers the user connected to.
  let recentServers: RecentServers
  /// Browser engines this edition ships.
  let browserProvider: DefaultBrowserEngineProvider
  /// The persisted engine choice, limited to `browserProvider.offeredEngines`.
  let browserPreferences: BrowserPreferences
  /// Light, dark or system, and the color theme, under the web's keys.
  let theme: ThemePreferences
  /// Sessions needing attention across windows, for the menu bar extra.
  let menuBar = MenuBarSessions()
  /// Which Keychain the cores store credentials in.
  let keychain: KeychainModeSelection.Choice
  /// Runs claimed agent browser actions; `nil` in the App Store edition.
  let agentBrowser: AgentBrowserPerformer?
  /// Why automatic updates are off, when the updater could not start.
  var updaterIssue: String?
  @ObservationIgnored private var notificationAuthorizationRequested = false

  /// Creates the services.
  /// - Parameters:
  ///   - desktop: The delegate's shell services.
  ///   - defaults: Store for recent servers and the engine choice.
  init(desktop: DesktopController, defaults: UserDefaults = .standard) {
    self.desktop = desktop
    logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.omnigent.mac", category: "app")
    recentServers = RecentServers(defaults: defaults)
    browserProvider = AppEdition.makeBrowserProvider()
    browserPreferences = BrowserPreferences(defaults: defaults, provider: browserProvider)
    theme = ThemePreferences(defaults: defaults)
    keychain = KeychainModeSelection.current()
    agentBrowser = AgentBrowserPerformer.forEdition(provider: browserProvider)
  }

  /// Binds the shell to the app: issues go to the log, and deep links trust known servers.
  /// Called before launch finishes.
  func bind() {
    let logger = logger
    desktop.onIssue = { issue in Self.log(issue, to: logger) }
    desktop.router.knownServers = { [weak self] in self?.knownServers() ?? [] }
    desktop.router.rememberServer = { [weak self] url in self?.recentServers.record(url) }
    if let reason = keychain.fallbackReason {
      logger.notice("\(reason, privacy: .public)")
    }
    for error in theme.readErrors {
      logger.error("\(error.description, privacy: .public)")
    }
    for entry in recentServers.rejectedEntries {
      logger.error("Ignored a stored recent server that is not a URL: \(entry, privacy: .public)")
    }
    let engines = browserProvider.offeredEngines.map(\.rawValue).joined(separator: ", ")
    logger.notice(
      """
      Omnigent \(AppEdition.current.displayName, privacy: .public) edition; browser engines: \
      \(engines, privacy: .public); default \(self.browserPreferences.engine.rawValue, privacy: .public)
      """)
  }

  /// The default server, recent servers and the organization's servers.
  /// - Returns: Servers deep links may open without a prompt.
  func knownServers() -> [URL] {
    var servers = [desktop.preferences.defaultServerURL].compactMap(\.self) + recentServers.urls
    do {
      servers += try desktop.managedPreferences.servers().servers.map(\.url)
    } catch {
      logger.error(
        "Organization servers ignored: \(error.localizedSummary, privacy: .public)")
    }
    return servers
  }

  /// The servers the sign-in picker offers: the organization's, then recent ones.
  /// - Returns: The directory.
  func serverDirectory() -> ServerDirectory {
    var managed: [ManagedServerEntry] = []
    var forced = false
    do {
      let servers = try desktop.managedPreferences.servers()
      forced = servers.serversAreForced
      managed = servers.servers.map {
        ManagedServerEntry(
          url: $0.url.absoluteString, name: $0.name, origin: $0.origin.serialized,
          authority: $0.origin.authority, displayName: $0.displayName)
      }
    } catch {
      logger.error(
        "Organization servers ignored: \(error.localizedSummary, privacy: .public)")
    }
    return ServerDirectory(
      managed: managed, serversAreForced: forced,
      recentServers: recentServers.urls.map(\.absoluteString))
  }

  /// A new window's server session over the live services.
  /// - Returns: The session.
  func makeServerSession() -> ServerSession {
    if ProcessInfo.processInfo.arguments.contains("-OmnigentDemo") {
      do {
        return try ServerSession.demo()
      } catch {
        logger.error("The demo server did not load: \(String(describing: error), privacy: .public)")
      }
    }
    let session = ServerSession.live(keychain: keychain)
    session.connection.browserActions?.performer = agentBrowser
    return session
  }

  /// Records a successful connection and, the first time, asks for notification permission:
  /// the moment the app has something to notify about.
  /// - Parameter serverURL: The server the window connected to.
  func didConnect(to serverURL: URL) async {
    recentServers.record(serverURL)
    await requestNotificationAuthorizationIfNeeded()
  }

  /// A browser controller for one server, isolated in that server's persistent profile.
  /// - Parameter serverURL: The server; the browser opens its page.
  /// - Returns: The controller.
  /// - Throws: `ServerOriginError` when `serverURL` is not an http(s) server URL.
  func makeBrowserController(serverURL: URL) throws(ServerOriginError) -> BrowserController {
    let origin = try ServerOrigin(url: serverURL)
    return BrowserController(
      profile: .server(origin.serialized), preferences: browserPreferences,
      provider: browserProvider, initialURL: serverURL)
  }

  private func requestNotificationAuthorizationIfNeeded() async {
    guard !notificationAuthorizationRequested, DesktopNotificationCenter.isAvailable else {
      return
    }
    notificationAuthorizationRequested = true
    let notifications = desktop.notifications
    do {
      try await notifications.refreshAuthorization()
      guard notifications.authorization == .notDetermined else { return }
      let granted = try await notifications.requestAuthorization()
      logger.notice("Notification permission \(granted ? "granted" : "declined", privacy: .public)")
    } catch {
      desktop.onIssue(.notificationFailed(error))
    }
  }

  private static func log(_ issue: DesktopIssue, to logger: Logger) {
    let message = String(describing: issue)
    switch issue {
    case .consentDeclined, .awaitingWindowOpener, .acknowledgmentDeclined:
      logger.notice("Desktop: \(message, privacy: .public)")
    case .deepLinkRejected, .acknowledgmentFailed, .invalidServerURL, .routingFailed,
      .notificationFailed, .unrecognizedNotificationPayload, .localServer:
      logger.error("Desktop: \(message, privacy: .public)")
    }
  }
}
