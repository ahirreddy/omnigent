import AppKit
public import Foundation

/// The desktop shell services, wired together: window registry, router, notifications, Dock
/// badge, preferences, managed preferences and the local server.
///
/// The app owns one, normally through `OmnigentDesktopAppDelegate`, and binds the closures on
/// `router` (known servers, remembering consented servers) to its connection store.
public final class DesktopController {
  /// User settings.
  public let preferences: DesktopPreferences
  /// Open windows.
  public let registry: ServerWindowRegistry
  /// Deep links and notification taps.
  public let router: DesktopRouter
  /// System notifications.
  public let notifications: DesktopNotificationCenter
  /// Organization-provided servers.
  public let managedPreferences: ManagedPreferences
  /// Settings > Local Server and the menu bar extra toggle.
  public let localServerPreferences: LocalServerPreferences
  /// Runs `omnigent server` and `omnigent host` on this Mac. Inert when the build cannot spawn
  /// processes (the App Store edition).
  public let localServer: LocalServerManager
  /// Asks whether to open a window on a local server the user just started. Defaults to
  /// `LocalServerReadyAlert.confirm`.
  public var confirmOpenLocalServer: (LocalServerEndpoint) async -> Bool = { endpoint in
    await LocalServerReadyAlert.confirm(endpoint)
  }
  private let relay: IssueRelay

  /// Receives every `DesktopIssue`. Defaults to standard error; bind to the app's logger.
  public var onIssue: DesktopIssueReporter {
    get { relay.handler }
    set { relay.handler = newValue }
  }

  /// Creates and wires the services.
  /// - Parameters:
  ///   - defaults: Store for `DesktopPreferences` and `LocalServerPreferences`.
  ///   - managedDomains: Managed-preference domains in precedence order.
  ///   - acknowledger: CLI handshake for `desktop_ack` links.
  ///   - localServerCapability: Whether this edition may spawn the CLI. Pass the edition's
  ///     value; the default detects App Sandbox.
  ///   - localServerDependencies: The local server's system access; tests and the example app
  ///     pass isolated ones.
  public init(
    defaults: UserDefaults = .standard,
    managedDomains: [String] = ManagedPreferences.domains(for: .main),
    acknowledger: any DeepLinkAcknowledging = LoopbackDeepLinkAcknowledger(),
    localServerCapability: LocalServerCapability = .detect(),
    localServerDependencies: LocalServerManager.Dependencies = .live(
      developmentCheckout: LocalServerManager.sourceCheckout)
  ) {
    let relay = IssueRelay()
    let report: DesktopIssueReporter = { relay.handler($0) }
    let preferences = DesktopPreferences(defaults: defaults)
    let registry = ServerWindowRegistry(reportIssue: report)
    let router = DesktopRouter(registry: registry, acknowledger: acknowledger, reportIssue: report)
    let notifications = DesktopNotificationCenter(reportIssue: report)

    registry.onUnreadTotalChange = { DockAttention.setBadge($0) }
    notifications.contextProvider = {
      registry.notificationContext(appIsActive: NSApplication.shared.isActive)
    }
    notifications.preferencesProvider = { preferences.notificationPreferences }
    notifications.soundNameProvider = { preferences.soundName }
    notifications.onActivate = { router.open($0.route, onServer: $0.serverURL) }

    self.relay = relay
    self.preferences = preferences
    self.registry = registry
    self.router = router
    self.notifications = notifications
    managedPreferences = ManagedPreferences(domains: managedDomains)
    localServerPreferences = LocalServerPreferences(defaults: defaults)
    localServer = LocalServerManager(
      capability: localServerCapability, preferences: localServerPreferences,
      dependencies: localServerDependencies)
    localServer.reportIssue = { report(.localServer($0)) }
    localServer.confirmHostMode = { await HostModeConfirmation.confirm(serverURL: $0) }
    localServer.onServerReady = { [weak self] endpoint, trigger in
      guard trigger == .user else { return }
      Task { await self?.offerWindow(on: endpoint) }
    }
  }

  /// After the user starts a local server, offers to open a window on it unless one is open.
  /// - Parameter endpoint: The ready server.
  func offerWindow(on endpoint: LocalServerEndpoint) async {
    let origin: ServerOrigin
    do {
      origin = try ServerOrigin(url: endpoint.url)
    } catch {
      relay.handler(.invalidServerURL(endpoint.url, error))
      return
    }
    guard !registry.activeOrigins.contains(origin) else { return }
    guard await confirmOpenLocalServer(endpoint) else { return }
    router.open(.home, onServer: endpoint.url)
  }

  /// Starts a monitor whose `triggers` stream yields on wake, unlock and session switch. Keep it
  /// alive while consuming; it stops when released.
  /// - Returns: The monitor.
  public func makeReconnectMonitor() -> SystemWakeMonitor {
    SystemWakeMonitor()
  }
}

extension ManagedPreferences {
  /// Info.plist Boolean. When `true` the app reads only its own preference domain.
  ///
  /// Sandboxed builds (the Mac App Store edition) set it: reading another app's domain from App
  /// Sandbox needs a `temporary-exception.shared-preference.read-only` entitlement, which App
  /// Review may reject. MDM profiles for that edition target its own bundle identifier.
  nonisolated public static let ownDomainOnlyInfoKey = "OmnigentManagedPreferencesOwnDomainOnly"

  /// The app's own domain first (so Debug `.lab` builds can be tested locally), then
  /// `defaultDomains`, without duplicates.
  /// - Parameters:
  ///   - bundleIdentifier: `Bundle.main.bundleIdentifier`.
  ///   - ownDomainOnly: Read only `bundleIdentifier`'s domain.
  /// - Returns: Domains in precedence order.
  nonisolated public static func domains(
    forBundleIdentifier bundleIdentifier: String?, ownDomainOnly: Bool = false
  ) -> [String] {
    let own = [bundleIdentifier].compactMap(\.self)
    if ownDomainOnly { return own }
    var domains: [String] = []
    for domain in own + defaultDomains where !domains.contains(domain) {
      domains.append(domain)
    }
    return domains
  }

  /// Domains for an app bundle, honoring `ownDomainOnlyInfoKey`.
  /// - Parameter bundle: Normally `.main`.
  /// - Returns: Domains in precedence order.
  nonisolated public static func domains(for bundle: Bundle) -> [String] {
    domains(
      forBundleIdentifier: bundle.bundleIdentifier,
      ownDomainOnly: bundle.object(forInfoDictionaryKey: ownDomainOnlyInfoKey) as? Bool ?? false)
  }
}

private final class IssueRelay {
  var handler: DesktopIssueReporter = StandardErrorIssueReporter.report
}
