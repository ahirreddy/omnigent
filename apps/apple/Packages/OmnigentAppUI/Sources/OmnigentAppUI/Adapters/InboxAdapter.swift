import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// Builds the inbox from the session list: sessions that need the user first, then unread
/// sessions, newest first within each. The header count is the shared attention model's.
enum InboxAdapter {
  /// The inbox's view state.
  /// - Parameter list: The session list.
  /// - Returns: The state.
  static func state(list: SessionListStore) -> InboxViewState {
    let waiting = list.needsResponse
    let unreadSessions = list.sessionsByID.values
      .filter { list.attention(of: $0.id).state == .unread }
      .sorted { $0.updatedAt > $1.updatedAt }
    let items =
      waiting.map { item($0, kind: .approval, isUnread: list.unreadIDs.contains($0.id)) }
      + unreadSessions.map { item($0, kind: .unread, isUnread: true) }
    var state = InboxViewState(items: items)
    state.needsYouCount = Int(list.attentionTotals.sessionsNeedingYou)
    return state
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
