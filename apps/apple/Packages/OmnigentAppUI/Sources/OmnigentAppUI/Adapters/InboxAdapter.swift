import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the inbox from the session list and the badge: sessions waiting for an answer first,
/// then unread sessions, newest first within each.
enum InboxAdapter {
  /// The inbox's view state.
  /// - Parameters:
  ///   - list: The session list.
  ///   - notifications: The badge, which marks unread sessions.
  /// - Returns: The state.
  static func state(list: SessionListStore, notifications: NotificationsStore?) -> InboxViewState {
    let unread = Set(notifications?.badgeSessionIDs ?? [])
    let waiting = list.needsResponse
    let waitingIDs = Set(waiting.map(\.id))
    let unreadSessions = list.sessionsByID.values
      .filter { unread.contains($0.id) && !waitingIDs.contains($0.id) }
      .sorted { $0.updatedAt > $1.updatedAt }
    let items =
      waiting.map { item($0, kind: .approval, isUnread: unread.contains($0.id)) }
      + unreadSessions.map { item($0, kind: .unread, isUnread: true) }
    return InboxViewState(items: items)
  }

  private static func item(
    _ session: OmnigentCoreFFI.SessionSummary, kind: InboxItem.Kind, isUnread: Bool
  ) -> InboxItem {
    InboxItem(
      id: "\(kind)-\(session.id)", kind: kind, sessionId: session.id, sessionTitle: session.title,
      preview: session.preview,
      date: Date(timeIntervalSince1970: TimeInterval(session.updatedAt)), isUnread: isUnread)
  }
}
