import Observation
import OmnigentCoreFFI
import Synchronization
import Testing

@testable import OmnigentStores

/// The sidebar reads the list's sessions, visible order and attention; an update that changes
/// none of them must not notify it (a set notifies even when the value is unchanged).
@MainActor
struct SessionListNotificationTests {
  private func summary(_ id: String, updatedAt: Int64) -> SessionSummary {
    SessionSummary(
      id: id, title: id, preview: "", status: .idle, pendingRequests: 0, isReadOnly: false,
      updatedAt: updatedAt, workspace: "", agentName: "", isPinned: false, isArchived: false,
      permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true, canArchive: true)
  }

  @Test func anUnchangedListNotifiesNoReader() {
    let store = SessionListStore()
    let row = summary("a", updatedAt: 1)
    store.apply(.reset(sessions: [row, summary("b", updatedAt: 2)]))
    store.unreadIDs = ["a"]
    let notified = Mutex(0)
    withObservationTracking {
      _ = (store.sessionsByID, store.visible, store.attentionByID, store.attentionTotals)
    } onChange: {
      notified.withLock { $0 += 1 }
    }
    // The server resending a row, the same unread set or the same search changes nothing shown.
    store.apply(.upsert(sessions: [row]))
    store.unreadIDs = ["a"]
    store.searchText = ""
    #expect(notified.withLock { $0 } == 0)
    store.apply(.upsert(sessions: [summary("a", updatedAt: 3)]))
    #expect(notified.withLock { $0 } == 1)
  }
}
