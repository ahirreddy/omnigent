import Observation
import OmnigentCoreFFI
import Synchronization
import Testing

@testable import OmnigentStores

/// The session list notifies its views only when a derived value changes: with hundreds of
/// sessions every notification redraws the sidebar, tab strip, menu bar and Dock.
@MainActor
struct SessionListNotificationTests {
  private func summary(
    _ id: String, updatedAt: Int64, status: SessionListStatus = .idle, requests: UInt32 = 0
  ) -> SessionSummary {
    SessionSummary(
      id: id, title: id, preview: "", status: status, pendingRequests: requests,
      isReadOnly: false,
      updatedAt: updatedAt, workspace: "", agentName: "", isPinned: false, isArchived: false,
      permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true, canArchive: true)
  }

  @Test("a server row or setting that changes nothing notifies no view")
  func unchangedRowsDoNotNotify() {
    let store = SessionListStore()
    let rows = [summary("a", updatedAt: 1), summary("b", updatedAt: 2, status: .running)]
    store.apply(.reset(sessions: rows))
    store.unreadIDs = ["a"]
    let notified = Mutex(false)
    withObservationTracking {
      _ = (store.sessionsByID, store.visible, store.attentionByID, store.attentionTotals)
    } onChange: {
      notified.withLock { $0 = true }
    }
    store.apply(.upsert(sessions: [rows[1]]))
    store.unreadIDs = ["a"]
    store.searchText = ""
    #expect(!notified.withLock { $0 })
    store.apply(.upsert(sessions: [summary("b", updatedAt: 3)]))
    #expect(notified.withLock { $0 })
    #expect(store.attention(of: "b").state == .idle)
    #expect(store.attention(of: "a").state == .unread)
  }

  @Test("the sessions needing the user are kept, and notify only when they change")
  func needsResponseIsStored() {
    let store = SessionListStore()
    store.apply(
      .reset(sessions: [
        summary("a", updatedAt: 1, status: .needsResponse, requests: 1),
        summary("b", updatedAt: 2),
      ]))
    #expect(store.needsResponse.map(\.id) == ["a"])
    let notified = Mutex(false)
    withObservationTracking {
      _ = store.needsResponse
    } onChange: {
      notified.withLock { $0 = true }
    }
    // Another session's row changes; the sessions needing the user do not.
    store.apply(.upsert(sessions: [summary("b", updatedAt: 3, status: .running)]))
    #expect(!notified.withLock { $0 })
    store.apply(
      .upsert(sessions: [summary("c", updatedAt: 4, status: .needsResponse, requests: 2)]))
    #expect(notified.withLock { $0 })
    #expect(store.needsResponse.map(\.id) == ["c", "a"])
  }
}
