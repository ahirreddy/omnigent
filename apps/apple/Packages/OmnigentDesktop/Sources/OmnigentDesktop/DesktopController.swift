import AppKit
public import Foundation

/// The desktop shell services, wired together: window registry, router, notifications, Dock
/// badge, preferences and managed preferences.
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
  private let relay: IssueRelay

  /// Receives every `DesktopIssue`. Defaults to standard error; bind to the app's logger.
  public var onIssue: DesktopIssueReporter {
    get { relay.handler }
    set { relay.handler = newValue }
  }

  /// Creates and wires the services.
  /// - Parameters:
  ///   - defaults: Store for `DesktopPreferences`.
  ///   - managedDomains: Managed-preference domains in precedence order.
  ///   - acknowledger: CLI handshake for `desktop_ack` links.
  public init(
    defaults: UserDefaults = .standard,
    managedDomains: [String] = ManagedPreferences.domains(
      forBundleIdentifier: Bundle.main.bundleIdentifier),
    acknowledger: any DeepLinkAcknowledging = LoopbackDeepLinkAcknowledger()
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
  }

  /// Starts a monitor whose `triggers` stream yields on wake, unlock and session switch. Keep it
  /// alive while consuming; it stops when released.
  /// - Returns: The monitor.
  public func makeReconnectMonitor() -> SystemWakeMonitor {
    SystemWakeMonitor()
  }
}

extension ManagedPreferences {
  /// The app's own domain first (so Debug `.lab` builds can be tested locally), then
  /// `defaultDomains`, without duplicates.
  /// - Parameter bundleIdentifier: `Bundle.main.bundleIdentifier`.
  /// - Returns: Domains in precedence order.
  nonisolated public static func domains(forBundleIdentifier bundleIdentifier: String?)
    -> [String]
  {
    var domains: [String] = []
    for domain in [bundleIdentifier].compactMap(\.self) + defaultDomains
    where !domains.contains(domain) {
      domains.append(domain)
    }
    return domains
  }
}

private final class IssueRelay {
  var handler: DesktopIssueReporter = StandardErrorIssueReporter.report
}
