import Observation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The list hands the core's index the rows that changed. What it keeps must be what filtering
/// every session would give, and a change that only rewrites a row's own text must not count as
/// one that moves it.
@MainActor
struct SessionListIndexTests {
  private func summary(
    _ id: String, updatedAt: Int64, status: SessionListStatus = .idle, requests: UInt32 = 0,
    pinned: Bool = false, archived: Bool = false
  ) -> SessionSummary {
    SessionSummary(
      id: id, title: "Session \(id)", preview: "", status: status, pendingRequests: requests,
      isReadOnly: false, updatedAt: updatedAt, workspace: "", agentName: "", isPinned: pinned,
      isArchived: archived, permissionLevel: 4, failureMessage: nil, canRename: true,
      canPin: true, canArchive: true)
  }

  /// Fails unless every kept value is what the core computes from all the sessions at once.
  private func expectKeptValuesMatchTheCore(_ store: SessionListStore, _ step: String) {
    let all = Array(store.sessionsByID.values)
    let unread = Array(store.unreadIDs)
    #expect(
      store.visible == filterSessions(sessions: all, text: store.searchText, filter: store.filter),
      "visible after \(step)")
    #expect(store.hasSeveralVisible == (store.visible.count > 1), "several after \(step)")
    #expect(
      store.attentionTotals == attentionTotals(sessions: all, unreadIds: unread),
      "totals after \(step)")
    let attention = Dictionary(
      uniqueKeysWithValues: all.map { session in
        (
          session.id,
          sessionAttention(session: session, isUnread: store.unreadIDs.contains(session.id))
        )
      })
    #expect(store.attentionByID == attention, "attention after \(step)")
    let needing = all.filter { attention[$0.id]?.state == .needsYou }
    #expect(
      store.needsResponse == filterSessions(sessions: needing, text: "", filter: .needsResponse),
      "needs response after \(step)")
    #expect(store.contents.visible == store.visible, "contents after \(step)")
    #expect(store.contents.attention == store.attentionByID, "contents after \(step)")
    #expect(store.contents.totals == store.attentionTotals, "contents after \(step)")
  }

  private typealias Step = (String, () -> Void)

  /// Rows arriving, changing in place, moving and asking for the user.
  private func rowSteps(_ store: SessionListStore) -> [Step] {
    let first = [
      summary("a", updatedAt: 1), summary("b", updatedAt: 2, status: .running),
      summary("c", updatedAt: 3, status: .needsResponse, requests: 2),
      summary("d", updatedAt: 4, archived: true),
    ]
    let asking = [
      summary("b", updatedAt: 2, status: .needsResponse, requests: 1),
      summary("e", updatedAt: 5, status: .needsResponse, requests: 3),
    ]
    let answered = summary("e", updatedAt: 5, status: .needsResponse, requests: 1)
    return [
      ("the first rows", { store.apply(.reset(sessions: first)) }),
      ("a row in place", { store.apply(.upsert(sessions: [self.summary("c", updatedAt: 3)])) }),
      ("a row that moves", { store.apply(.upsert(sessions: [self.summary("a", updatedAt: 9)])) }),
      ("two that need the user", { store.apply(.upsert(sessions: asking)) }),
      ("one of them answered in place", { store.apply(.upsert(sessions: [answered])) }),
      ("an expected status", { store.expect(.running, for: "b") }),
      ("unread marks", { store.unreadIDs = ["a", "d", "gone"] }),
      (
        "a pin", { store.apply(.upsert(sessions: [self.summary("c", updatedAt: 3, pinned: true)])) }
      ),
    ]
  }

  /// A search, a filter, a removal, a reload and signing out.
  private func listSteps(_ store: SessionListStore) -> [Step] {
    let archived = summary("d", updatedAt: 8, archived: true)
    let reload = [summary("b", updatedAt: 2), summary("f", updatedAt: 7, status: .running)]
    return [
      ("a search", { store.searchText = "session b" }),
      ("a filter", { store.filter = .archived }),
      ("a row under a filter", { store.apply(.upsert(sessions: [archived])) }),
      ("the search cleared", { store.searchText = "" }),
      ("every session again", { store.filter = .all }),
      ("a removal", { store.apply(.remove(ids: ["a", "unknown"])) }),
      ("a reload", { store.apply(.reset(sessions: reload)) }),
      ("the same reload", { store.apply(.reset(sessions: reload)) }),
      ("signing out", { store.clear() }),
    ]
  }

  @Test("what the list keeps is what the core gives for all the sessions, after every change")
  func keptValuesMatchTheCore() {
    let store = SessionListStore()
    for (step, change) in rowSteps(store) + listSteps(store) {
      change()
      expectKeptValuesMatchTheCore(store, step)
    }
    #expect(store.visible.isEmpty)
    #expect(store.contents.unreadIDs.isEmpty)
  }

  @Test("a row's own text, status and marks do not count as a move; order, pins and search do")
  func placementCountsOnlyMoves() {
    let store = SessionListStore()
    let rows = [summary("a", updatedAt: 1), summary("b", updatedAt: 2), summary("c", updatedAt: 3)]
    store.apply(.reset(sessions: rows))
    #expect(store.visible.map(\.id) == ["c", "b", "a"])
    var revision = store.placementRevision
    let stays: (String, () -> Void) -> Void = { step, change in
      change()
      #expect(store.placementRevision == revision, "\(step) counted as a move")
    }
    let moves: (String, () -> Void) -> Void = { step, change in
      change()
      #expect(store.placementRevision == revision + 1, "\(step) did not count as one move")
      revision = store.placementRevision
    }
    var first = summary("c", updatedAt: 6, status: .running)
    first.title = "Renamed"
    first.preview = "A new message"
    first.canStop = true
    stays("the first row's text, time and status") { store.apply(.upsert(sessions: [first])) }
    #expect(store.visible.first == first)
    stays("an unchanged row") { store.apply(.upsert(sessions: [first])) }
    stays("a read mark") { store.unreadIDs = ["a"] }
    stays("a draft") { store.setDraft("a", true) }
    stays("an expected status") { store.expect(.needsResponse, for: "b") }
    #expect(store.visible[1].status == .needsResponse)
    var asked = summary("b", updatedAt: 2, status: .needsResponse, requests: 1)
    stays("a request") { store.apply(.upsert(sessions: [asked])) }
    asked.preview = "Approve?"
    stays("a waiting row's text") { store.apply(.upsert(sessions: [asked])) }
    #expect(store.needsResponse == [asked])
    var pinned = summary("a", updatedAt: 9)
    moves("a row that passes another") { store.apply(.upsert(sessions: [pinned])) }
    #expect(store.visible.map(\.id) == ["a", "c", "b"])
    pinned.isPinned = true
    moves("a pin that keeps the order") { store.apply(.upsert(sessions: [pinned])) }
    pinned.workspace = "/work/a"
    moves("a workspace") { store.apply(.upsert(sessions: [pinned])) }
    moves("a search") { store.searchText = "renamed" }
    #expect(store.visible.map(\.id) == ["c"])
    stays("a search that shows the same") { store.searchText = "Renamed" }
    moves("a filter") { store.filter = .archived }
    moves("a session that arrives") {
      store.apply(.upsert(sessions: [self.summary("d", updatedAt: 4, archived: true)]))
    }
    moves("a session that leaves") { store.apply(.remove(ids: ["d"])) }
    stays("a hidden row's text") {
      store.apply(.upsert(sessions: [self.summary("b", updatedAt: 3)]))
    }
  }

  @Test("a view that read one session's read mark or draft is not notified for another's")
  func marksNotifyTheirOwnSession() {
    let store = SessionListStore()
    store.apply(.reset(sessions: [summary("a", updatedAt: 1), summary("b", updatedAt: 2)]))
    let unreadOfA = { _ = store.isUnread("a") }
    #expect(!observationNotifies(unreadOfA) { store.unreadIDs = ["b"] })
    #expect(!store.isUnread("a"))
    #expect(observationNotifies(unreadOfA) { store.unreadIDs = ["a", "b"] })
    #expect(store.isUnread("a"))
    #expect(observationNotifies(unreadOfA) { store.unreadIDs = ["b"] })
    let draftOfA = { _ = store.hasDraft("a") }
    #expect(!observationNotifies(draftOfA) { store.setDraft("b", true) })
    #expect(!store.hasDraft("a"))
    #expect(observationNotifies(draftOfA) { store.setDraft("a", true) })
    #expect(store.hasDraft("a"))
    #expect(store.contents.draftSessionIDs == ["a", "b"])
    // Signing out clears both, and says so.
    #expect(observationNotifies(draftOfA) { store.clear() })
    #expect(!store.hasDraft("a"))
  }

  @Test("the rows read without observing notify no one; the revision is the reader's signal")
  func contentsAreNotObserved() {
    let store = SessionListStore()
    store.apply(.reset(sessions: [summary("a", updatedAt: 1), summary("b", updatedAt: 2)]))
    let reads = { _ = (store.contents, store.placementRevision) }
    #expect(
      !observationNotifies(reads) {
        store.apply(.upsert(sessions: [self.summary("b", updatedAt: 3)]))
      })
    #expect(store.contents.visible.first?.updatedAt == 3)
    #expect(!observationNotifies(reads) { store.unreadIDs = ["a"] })
    #expect(store.contents.unreadIDs == ["a"])
    #expect(
      observationNotifies(reads) {
        store.apply(.upsert(sessions: [self.summary("a", updatedAt: 4)]))
      })
  }

  private final class Follower: SessionListFollower {
    var told = 0

    func sessionListChanged(_ list: SessionListStore) {
      told += 1
    }
  }

  @Test("a follower is told once after each change, and is not kept alive")
  func followersAreToldAndHeldWeakly() {
    let store = SessionListStore()
    let follower = Follower()
    store.follow(follower)
    store.follow(follower)
    store.apply(.reset(sessions: [summary("a", updatedAt: 1), summary("b", updatedAt: 2)]))
    #expect(follower.told == 1)
    store.apply(.upsert(sessions: [summary("a", updatedAt: 1)]))
    #expect(follower.told == 1, "an unchanged row is not a change")
    store.unreadIDs = ["a"]
    store.setDraft("b", true)
    store.searchText = "a"
    #expect(follower.told == 4)
    var dropped: Follower? = Follower()
    weak let held = dropped
    if let dropped { store.follow(dropped) }
    dropped = nil
    #expect(held == nil)
    store.filter = .archived
    #expect(follower.told == 5)
  }
}
