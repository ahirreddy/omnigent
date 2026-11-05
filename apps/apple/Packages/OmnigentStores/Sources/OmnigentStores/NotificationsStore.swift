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
  /// Indexes in ``pending`` of sessions' own finished turns, whose body can be the reply.
  @ObservationIgnored private var ownTurnEnds: Set<Int> = []

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
      ownTurnEnds = []
      rollup.reset()
    }
    return pending
  }

  /// Hands the pending notifications to the presenter, as the web does: a session's own finished
  /// turn carries the agent's reply preview as its body. Without a reply, or when it cannot be
  /// read, the core's default body stays.
  /// - Returns: The notifications, oldest first, and the reads that failed.
  public func takeWithReplyPreviews() async -> (
    notifications: [AttentionNotification], failures: [CoreError]
  ) {
    let previewed = ownTurnEnds
    var notifications = take()
    var failures: [CoreError] = []
    for index in previewed.sorted() where notifications.indices.contains(index) {
      do {
        let output = try await core.latestOutput(sessionId: notifications[index].sessionId)
        if let preview = output?.preview, !preview.isEmpty { notifications[index].body = preview }
      } catch {
        failures.append(coreError(error))
      }
    }
    return (notifications, failures)
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
    // A top-level turn end is appended as is; rollups only replace their own earlier entries.
    if notification.kind == .completed, parent == nil || parent?.id == notification.sessionId {
      ownTurnEnds.insert(pending.count)
    }
    rollup.add(
      notification, to: &pending, parent: parent,
      childTitle: list.session(notification.sessionId)?.title)
  }

  func badge(_ ids: [String]) {
    badgeSessionIDs = ids
  }
}
