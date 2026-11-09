public import Foundation
public import Observation

/// Live state of every server window: binding, readiness, viewed session and unread count.
///
/// Windows report through `View.serverWindow(_:desktop:...)`. The registry feeds deep-link
/// routing, notification suppression and the Dock badge.
@Observable
public final class ServerWindowRegistry {
  /// One open window.
  public struct Entry: Equatable, Sendable {
    /// The window's current value.
    public var id: ServerWindowID
    /// The bound server's origin, or `nil` on the connect screen.
    public var origin: ServerOrigin?
    /// Whether the window is connected and can navigate in place.
    public var isReady: Bool
    /// The conversation the window shows, if any.
    public var viewedSessionID: String?
    /// The server-wide unread count the window last reported.
    public var unreadCount: Int
  }

  /// Open windows in creation order.
  public private(set) var entries: [Entry] = []
  /// The instance of the key window, if it is a server window.
  public private(set) var keyWindow: UUID?
  private var pendingRoutes: [UUID: DeepLinkRoute] = [:]

  /// Called with the new Dock badge total whenever it changes.
  @ObservationIgnored public var onUnreadTotalChange: (Int) -> Void = { _ in }
  @ObservationIgnored private let reportIssue: DesktopIssueReporter
  @ObservationIgnored private var lastUnreadTotal = 0
  @ObservationIgnored private var routeHandlers: [UUID: (DeepLinkRoute) -> Void] = [:]

  /// Creates an empty registry.
  /// - Parameter reportIssue: Receives windows bound to invalid server URLs.
  public init(reportIssue: @escaping DesktopIssueReporter = StandardErrorIssueReporter.report) {
    self.reportIssue = reportIssue
  }

  /// Adds or updates a window.
  /// - Parameters:
  ///   - id: The window's current value.
  ///   - isReady: Whether it is connected.
  ///   - viewedSessionID: The conversation it shows.
  ///   - unreadCount: Its server's unread count.
  public func update(
    _ id: ServerWindowID, isReady: Bool, viewedSessionID: String?, unreadCount: Int
  ) {
    let origin: ServerOrigin?
    do {
      origin = try id.origin
    } catch {
      origin = nil
      if let url = id.serverURL { reportIssue(.invalidServerURL(url, error)) }
    }
    let entry = Entry(
      id: id, origin: origin, isReady: isReady && origin != nil,
      viewedSessionID: viewedSessionID, unreadCount: max(0, unreadCount))
    if let index = entries.firstIndex(where: { $0.id.instance == id.instance }) {
      guard entries[index] != entry else { return }
      entries[index] = entry
    } else {
      entries.append(entry)
    }
    publishUnreadTotal()
    applyPendingRoute(for: id.instance)
  }

  /// Sets what shows a window's routes, and applies one already waiting if the window can.
  /// - Parameters:
  ///   - instance: The window's instance.
  ///   - handler: Shows a route in the window.
  public func setRouteHandler(
    for instance: UUID, _ handler: @escaping (DeepLinkRoute) -> Void
  ) {
    routeHandlers[instance] = handler
    applyPendingRoute(for: instance)
  }

  /// Forgets a closed window and any route waiting for it.
  /// - Parameter instance: The window's instance.
  public func remove(_ instance: UUID) {
    entries.removeAll { $0.id.instance == instance }
    pendingRoutes[instance] = nil
    routeHandlers[instance] = nil
    if keyWindow == instance { keyWindow = nil }
    publishUnreadTotal()
  }

  /// Records whether a window is key.
  /// - Parameters:
  ///   - instance: The window's instance.
  ///   - isKey: Whether it is now key.
  public func setKey(_ instance: UUID, isKey: Bool) {
    if isKey {
      keyWindow = instance
    } else if keyWindow == instance {
      keyWindow = nil
    }
  }

  /// The entry for an instance.
  /// - Parameter instance: The window's instance.
  /// - Returns: The entry, if the window is open.
  public func entry(_ instance: UUID) -> Entry? {
    entries.first { $0.id.instance == instance }
  }

  /// Queues a route for a window, which shows it through its route handler once it is ready.
  /// - Parameters:
  ///   - route: The destination.
  ///   - instance: The window's instance; it need not be open yet.
  public func deliver(_ route: DeepLinkRoute, to instance: UUID) {
    pendingRoutes[instance] = route
    applyPendingRoute(for: instance)
  }

  /// Hands a waiting route to the window's handler when the window can take it.
  private func applyPendingRoute(for instance: UUID) {
    guard let handler = routeHandlers[instance], let route = takePendingRoute(for: instance)
    else { return }
    handler(route)
  }

  /// The route waiting for a window.
  /// - Parameter instance: The window's instance.
  /// - Returns: The route, if any.
  public func pendingRoute(for instance: UUID) -> DeepLinkRoute? {
    pendingRoutes[instance]
  }

  /// Removes and returns the route waiting for a ready window, or for any open window when the
  /// route applies before sign-in (an invite).
  /// - Parameter instance: The window's instance.
  /// - Returns: The route, or `nil` when none is waiting or the window cannot take it yet.
  public func takePendingRoute(for instance: UUID) -> DeepLinkRoute? {
    guard let entry = entry(instance), let route = pendingRoutes[instance],
      entry.isReady || route.appliesBeforeSignIn
    else {
      return nil
    }
    pendingRoutes[instance] = nil
    return route
  }

  /// Snapshots for `DeepLinkRouting`.
  public var routingSnapshots: [WindowRoutingSnapshot<UUID>] {
    entries.map {
      WindowRoutingSnapshot(id: $0.id.instance, origin: $0.origin, isReady: $0.isReady)
    }
  }

  /// Distinct servers with an open window.
  public var activeOrigins: Set<ServerOrigin> { Set(entries.compactMap(\.origin)) }

  /// The Dock badge total: each server's count once (the maximum across its windows, which report
  /// the same server-wide number), summed across servers.
  public var unreadTotal: Int {
    var perOrigin: [ServerOrigin: Int] = [:]
    for entry in entries {
      guard let origin = entry.origin else { continue }
      perOrigin[origin] = max(perOrigin[origin] ?? 0, entry.unreadCount)
    }
    return perOrigin.values.reduce(0, +)
  }

  /// What notification suppression needs to know about the key window.
  /// - Parameter appIsActive: Whether the app is frontmost.
  /// - Returns: The context.
  public func notificationContext(appIsActive: Bool) -> NotificationContext {
    let key = keyWindow.flatMap(entry)
    let viewing: ViewedSession? =
      if let origin = key?.origin, let session = key?.viewedSessionID {
        ViewedSession(origin: origin, sessionID: session)
      } else {
        nil
      }
    return NotificationContext(
      appIsActive: appIsActive, viewing: viewing, activeServerCount: activeOrigins.count)
  }

  private func publishUnreadTotal() {
    let total = unreadTotal
    guard total != lastUnreadTotal else { return }
    lastUnreadTotal = total
    onUnreadTotalChange(total)
  }
}
