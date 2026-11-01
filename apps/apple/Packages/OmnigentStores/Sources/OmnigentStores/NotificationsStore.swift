public import Observation
public import OmnigentCoreFFI

/// Notifications the core decided to show, and the app badge.
@Observable
public final class NotificationsStore {
  /// Notifications not yet taken by the presenter, oldest first.
  public private(set) var pending: [AttentionNotification] = []
  /// Sessions counting toward the badge.
  public private(set) var badgeSessionIDs: [String] = []
  /// Whether the app may show notifications.
  public private(set) var isAllowed = false

  private let core: ClientCore

  init(core: ClientCore) {
    self.core = core
  }

  /// The badge count.
  public var badgeCount: Int { badgeSessionIDs.count }

  /// Hands the pending notifications to the presenter.
  /// - Returns: The notifications, oldest first.
  public func take() -> [AttentionNotification] {
    defer { pending = [] }
    return pending
  }

  /// Records whether notification permission was granted.
  /// - Parameter allowed: Whether the app may show notifications.
  public func setAllowed(_ allowed: Bool) {
    isAllowed = allowed
    core.setNotificationsAllowed(allowed: allowed)
  }

  func notify(_ notification: AttentionNotification) {
    pending.append(notification)
  }

  func badge(_ ids: [String]) {
    badgeSessionIDs = ids
  }
}
