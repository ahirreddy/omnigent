import Foundation
import OSLog
import OmnigentBrowser
import OmnigentDesktop

/// App-wide services shared by every window: the desktop shell, recent servers, the browser
/// engines and the log.
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
  private var notificationAuthorizationRequested = false

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
  }

  /// Binds the shell to the app: issues go to the log, and deep links trust known servers.
  /// Called before launch finishes.
  func bind() {
    let logger = logger
    desktop.onIssue = { issue in Self.log(issue, to: logger) }
    desktop.router.knownServers = { [weak self] in self?.knownServers() ?? [] }
    desktop.router.rememberServer = { [weak self] url in self?.recentServers.record(url) }
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
      .notificationFailed, .unrecognizedNotificationPayload:
      logger.error("Desktop: \(message, privacy: .public)")
    }
  }
}
