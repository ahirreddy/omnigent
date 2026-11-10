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

  /// Whether reading `read` is notified by `change`.
  private func notifies(_ read: () -> Void, when change: () -> Void) -> Bool {
    let notified = Mutex(false)
    withObservationTracking(read) { notified.withLock { $0 = true } }
    change()
    return notified.withLock { $0 }
  }

  @Test("a view that read one session is not notified for another session's row")
  func oneSessionsReaderIgnoresOtherSessions() {
    let store = SessionListStore()
    store.apply(.reset(sessions: [summary("a", updatedAt: 1), summary("b", updatedAt: 2)]))
    let readsA = { _ = (store.session("a"), store.attention(of: "a"), store.parent(of: "a")) }
    let changeB = { store.apply(.upsert(sessions: [self.summary("b", updatedAt: 3)])) }
    #expect(!notifies(readsA, when: changeB))
    #expect(!notifies(readsA) { store.apply(.upsert(sessions: [self.summary("c", updatedAt: 4)])) })
    #expect(!notifies(readsA) { store.apply(.remove(ids: ["c"])) })
    #expect(!notifies(readsA) { store.unreadIDs = ["b"] })
    // Its own row, read state and removal reach it.
    #expect(notifies(readsA) { store.apply(.upsert(sessions: [self.summary("a", updatedAt: 5)])) })
    #expect(store.session("a")?.updatedAt == 5)
    #expect(notifies({ _ = store.attention(of: "a") }, when: { store.unreadIDs = ["a", "b"] }))
    #expect(store.attention(of: "a").state == .unread)
    // A changed row that leaves the attention alone notifies the summary's reader only.
    let rowOfB = { store.apply(.upsert(sessions: [self.summary("b", updatedAt: 6)])) }
    #expect(!notifies({ _ = store.attention(of: "b") }, when: rowOfB))
    #expect(notifies(readsA) { store.apply(.remove(ids: ["a"])) })
    #expect(store.session("a") == nil)
    // A session that arrives reaches the view that asked for it before it was known.
    let rowOfD = { store.apply(.upsert(sessions: [self.summary("d", updatedAt: 7)])) }
    #expect(notifies({ _ = store.session("d") }, when: rowOfD))
  }

  @Test("a view asking only whether there are several sessions hears of the second, not of rows")
  func severalVisibleNotifiesWhenItFlips() {
    let store = SessionListStore()
    let several = { _ = store.hasSeveralVisible }
    #expect(!store.hasSeveralVisible)
    #expect(!notifies(several) { store.apply(.reset(sessions: [self.summary("a", updatedAt: 1)])) })
    #expect(!store.hasSeveralVisible)
    #expect(notifies(several) { store.apply(.upsert(sessions: [self.summary("b", updatedAt: 2)])) })
    #expect(store.hasSeveralVisible)
    // A row that changes, and a third session, leave the answer as it is.
    #expect(
      !notifies(several) { store.apply(.upsert(sessions: [self.summary("a", updatedAt: 3)])) })
    #expect(
      !notifies(several) { store.apply(.upsert(sessions: [self.summary("c", updatedAt: 4)])) })
    #expect(notifies(several) { store.apply(.remove(ids: ["b", "c"])) })
    #expect(!store.hasSeveralVisible)
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
