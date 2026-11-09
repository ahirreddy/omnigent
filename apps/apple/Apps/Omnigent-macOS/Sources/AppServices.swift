import Foundation
import OSLog
import Observation
import OmnigentAppBrowser
import OmnigentAppUI
import OmnigentAuthUI
import OmnigentBrowser
import OmnigentDesktop
import OmnigentStores
import OmnigentUIComponents

/// The notification permission `AppServices` asks for after the first connection.
protocol NotificationAuthorizing: AnyObject {
  /// The last permission read.
  var authorization: DesktopNotificationCenter.Authorization { get }
  /// Re-reads the permission.
  func refreshAuthorization() async throws(DesktopNotificationError)
  /// Asks the person for permission.
  /// - Returns: Whether notifications are allowed.
  @discardableResult func requestAuthorization() async throws(DesktopNotificationError) -> Bool
}

extension DesktopNotificationCenter: NotificationAuthorizing {}

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
  /// The browser's profiles, history, bookmarks and prompts.
  let browser: BrowserEnvironment
  /// Browser tabs across windows.
  let browserTabs: BrowserTabHost
  /// Saves and restores each window's tabs; `nil` when Application Support is unavailable.
  let tabPersistence: TabPersistence?
  /// Set when the app starts quitting, so closing windows keep their saved tabs.
  @ObservationIgnored private(set) var isTerminating = false
  /// Why automatic updates are off, when the updater could not start.
  var updaterIssue: String?
  @ObservationIgnored private var notificationAuthorizationRequested = false
  @ObservationIgnored private let flushDrafts: () -> Void
  @ObservationIgnored private let notificationPermission: any NotificationAuthorizing
  @ObservationIgnored private let isDemo: Bool
  @ObservationIgnored private let makeDemoSession: @MainActor () throws -> ServerSession

  /// Where UI tests and the test host keep saved tabs instead of Application Support.
  static let tabsDirectoryKey = "OmnigentTabsDirectory"

  /// Creates the services.
  /// - Parameters:
  ///   - desktop: The delegate's shell services.
  ///   - defaults: Store for recent servers, browser settings and the engine choice.
  ///   - browserDirectory: Where the browser keeps profiles, history and bookmarks.
  ///   - flushDrafts: Saves the composer drafts when the app quits.
  ///   - notificationPermission: What asks for notification permission; `desktop`'s center when
  ///     `nil`.
  ///   - launchArguments: The process's arguments, where `-OmnigentDemo` asks for the demo.
  ///   - makeDemoSession: Makes a demo launch's sessions.
  ///   - applicationSupportTabs: Opens the saved tabs in Application Support, unless `defaults`
  ///     names another directory.
  init(
    desktop: DesktopController, defaults: UserDefaults = .standard,
    browserDirectory: URL = BrowserEnvironment.standardDirectory,
    // coverage:off rewrites the user's own drafts file; VM flow backlog: a draft survives quitting
    flushDrafts: @escaping () -> Void = { ComposerDraftArchive.shared?.flush() },
    // coverage:on
    notificationPermission: (any NotificationAuthorizing)? = nil,
    launchArguments: [String] = ProcessInfo.processInfo.arguments,
    makeDemoSession: @escaping @MainActor () throws -> ServerSession = ServerSession.demo,
    applicationSupportTabs: @MainActor (_ isDemo: Bool) throws -> TabPersistence = AppServices
      .standardTabs
  ) {
    isDemo = launchArguments.contains("-OmnigentDemo")
    self.makeDemoSession = makeDemoSession
    self.desktop = desktop
    self.flushDrafts = flushDrafts
    self.notificationPermission = notificationPermission ?? desktop.notifications
    logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ai.omnigent.mac", category: "app")
    recentServers = RecentServers(defaults: defaults)
    browserProvider = AppEdition.makeBrowserProvider()
    browserPreferences = BrowserPreferences(defaults: defaults, provider: browserProvider)
    theme = ThemePreferences(defaults: defaults)
    keychain = KeychainModeSelection.current()
    agentBrowser = AgentBrowserPerformer.forEdition(provider: browserProvider)
    browser = BrowserEnvironment(
      directory: browserDirectory, provider: browserProvider, preferences: browserPreferences,
      defaults: defaults)
    browserTabs = BrowserTabHost(
      environment: browser, agent: agentBrowser?.agentController, logger: logger)
    tabPersistence = Self.openTabs(
      directory: defaults.string(forKey: Self.tabsDirectoryKey), isDemo: isDemo, logger: logger,
      applicationSupport: applicationSupportTabs)
  }

  /// The saved tabs under Application Support.
  /// - Parameter isDemo: Whether this is a demo launch, whose tabs are kept apart.
  /// - Returns: The tabs.
  /// - Throws: When Application Support cannot be located.
  static func standardTabs(isDemo: Bool) throws -> TabPersistence {
    try TabPersistence.applicationSupport(
      bundleID: Bundle.main.bundleIdentifier ?? "ai.omnigent.mac", isDemo: isDemo)
  }

  /// The saved tabs; UI tests pass `-OmnigentTabsDirectory <path>` to keep the user's untouched.
  /// - Returns: The tabs, or `nil` (logged) when Application Support is unavailable.
  private static func openTabs(
    directory: String?, isDemo: Bool, logger: Logger,
    applicationSupport: @MainActor (Bool) throws -> TabPersistence
  ) -> TabPersistence? {
    if let directory { return TabPersistence(directory: URL(filePath: directory)) }
    do {
      return try applicationSupport(isDemo)
    } catch {
      logger.error("Tabs will not be saved: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// The app is quitting: save every window's tabs and the composer drafts now.
  func willTerminate() {
    isTerminating = true
    tabPersistence?.flush()
    flushDrafts()
  }

  /// A server window closed: unless the app is quitting, its page is forgotten and its browser
  /// pages close (sessions keep their saved tabs).
  /// - Parameter window: The window's instance.
  func windowClosed(_ window: UUID) {
    guard !isTerminating else { return }
    tabPersistence?.windowClosed(window)
    browserTabs.windowClosed(window)
  }

  /// Binds the shell to the app: issues go to the log, and deep links trust known servers.
  /// Called before launch finishes.
  func bind() {
    let logger = logger
    desktop.onIssue = { issue in Self.log(issue, to: logger) }
    desktop.router.knownServers = { [weak self] in self?.knownServers() ?? [] }
    desktop.router.rememberServer = { [weak self] url in self?.recentServers.record(url) }
    DesktopSupervision.install(on: desktop)
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
    [desktop.preferences.defaultServerURL].compactMap(\.self) + recentServers.urls
      + organizationServers()
  }

  /// The servers the organization provides (managed preferences).
  /// - Returns: Their URLs; none when the preferences cannot be read (logged).
  func organizationServers() -> [URL] {
    do {
      return try desktop.managedPreferences.servers().servers.map(\.url)
    } catch {
      logger.error(
        "Organization servers ignored: \(error.localizedSummary, privacy: .public)")
      return []
    }
  }

  /// Servers for Settings › Phone's pairing code: those with a signed-in window, then recents.
  /// - Returns: Server URLs, without repeats.
  func pairingServers() -> [String] {
    var seen: Set<String> = []
    return (SupervisionConnections.shared.serverURLs + recentServers.urls.map(\.absoluteString))
      .filter { seen.insert($0).inserted }
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
    if isDemo {
      do {
        return try makeDemoSession()
      } catch {
        logger.error("The demo server did not load: \(String(describing: error), privacy: .public)")
      }
    }
    let session = ServerSession.live(keychain: keychain)
    session.connection.browserActions?.performer = agentBrowser
    return session
  }

  /// Opens a conversation of a server in a window of its own, as Settings' session links do.
  /// - Parameters:
  ///   - server: The server.
  ///   - session: The conversation.
  func openSession(on server: URL, session: String) {
    desktop.router.open(.conversation(sessionID: session), onServer: server)
  }

  /// Records a successful connection and, the first time, asks for notification permission:
  /// the moment the app has something to notify about.
  /// - Parameter serverURL: The server the window connected to.
  func didConnect(to serverURL: URL) async {
    recentServers.record(serverURL)
    await requestNotificationAuthorizationIfNeeded()
  }

  private func requestNotificationAuthorizationIfNeeded() async {
    guard !notificationAuthorizationRequested, DesktopNotificationCenter.isAvailable else {
      return
    }
    notificationAuthorizationRequested = true
    do {
      try await notificationPermission.refreshAuthorization()
      guard notificationPermission.authorization == .notDetermined else { return }
      let granted = try await notificationPermission.requestAuthorization()
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
      .notificationFailed, .unrecognizedNotificationPayload, .localServer, .supervision:
      logger.error("Desktop: \(message, privacy: .public)")
    }
  }
}
