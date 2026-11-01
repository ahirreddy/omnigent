public import Observation
public import OmnigentCoreFFI

/// Notifications the core decided to show, and the app badge.
@Observable
public final class NotificationsStore {
  /// Notifications not yet taken by the presenter, oldest first.
  public private(set) var pending: [AttentionNotification] = []
  /// Sessions the core's notification tracker counts: waiting for input and not being viewed.
  /// The badge number is ``badgeCount``, from the shared attention model.
  public private(set) var badgeSessionIDs: [String] = []
  /// Whether the app may show notifications.
  public private(set) var isAllowed = false

  private let core: ClientCore
  /// The session list whose attention totals are the badge.
  private let list: SessionListStore
  /// Sub-agent notifications fold into their parent's.
  private var rollup = ChildNotificationRollup()

  init(core: ClientCore, list: SessionListStore) {
    self.core = core
    self.list = list
  }

  /// The badge count (Dock, app icon, menu bar): sessions that need the user, the same number as
  /// the sidebar's Inbox and Needs you counts (`AttentionTotals.sessionsNeedingYou`).
  public var badgeCount: Int { Int(list.attentionTotals.sessionsNeedingYou) }

  /// Hands the pending notifications to the presenter.
  /// - Returns: The notifications, oldest first.
  public func take() -> [AttentionNotification] {
    defer {
      pending = []
      rollup.reset()
    }
    return pending
  }

  /// Records whether notification permission was granted.
  /// - Parameter allowed: Whether the app may show notifications.
  public func setAllowed(_ allowed: Bool) {
    isAllowed = allowed
    core.setNotificationsAllowed(allowed: allowed)
  }

  func notify(_ notification: AttentionNotification) {
    let parent = list.parent(of: notification.sessionId).map {
      ChildNotificationRollup.Parent(id: $0, title: list.session($0)?.title)
    }
    rollup.add(
      notification, to: &pending, parent: parent,
      childTitle: list.session(notification.sessionId)?.title)
  }

  func badge(_ ids: [String]) {
    badgeSessionIDs = ids
  }
}
