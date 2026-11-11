import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The sidebar's kept state is the one a build from the list gives, its reader is told when a
/// row can have moved and not when a session says something new, and a row's own reader is told
/// of its session alone.
@MainActor
@Suite("Sidebar state memo and live rows")
struct SidebarStateMemoTests {
  private typealias Change = (step: String, apply: (SessionListStore) -> Void)

  private static let sessions = SidebarBenchmarks.sessions(8)

  private static func row(
    _ index: Int, _ edit: (inout OmnigentCoreFFI.SessionSummary) -> Void
  ) -> SessionListChange {
    var row = sessions[index]
    edit(&row)
    return .upsert(sessions: [row])
  }

  /// One session's own changes: none of them moves its row among rows sorted by update.
  private static let ownChanges: [Change] = [
    ("a preview", { $0.apply(row(3) { $0.preview = "A new message" }) }),
    ("a title", { $0.apply(row(3) { $0.title = "Renamed" }) }),
    ("a read mark", { $0.unreadIDs = ["s2"] }),
    ("a draft", { $0.setDraft("s1", true) }),
    ("a status", { $0.apply(row(3) { $0.status = .running }) }),
    (
      "a request",
      {
        $0.apply(
          row(3) {
            $0.status = .needsResponse
            $0.pendingRequests = 2
          })
      }
    ),
  ]

  /// Changes that move a row, or put other rows on screen.
  private static let moves: [Change] = [
    ("a row that passes the others", { $0.apply(row(5) { $0.updatedAt = 20_000 }) }),
    ("a pin", { $0.apply(row(6) { $0.isPinned = true }) }),
    ("a search", { $0.searchText = "#1" }),
    ("the search cleared", { $0.searchText = "" }),
    ("a filter", { $0.filter = .running }),
    ("every session again", { $0.filter = .all }),
    ("a removal", { $0.apply(.remove(ids: ["s7"])) }),
    ("the projects", { $0.projects = Array(SidebarBenchmarks.projects.prefix(2)) }),
    ("a page", { $0.paging.pagingChanged(hasMore: true, isLoading: false) }),
  ]

  @Test(
    "After every change the kept state is the one built from the list",
    arguments: [
      SessionDisplayOptions(), SessionDisplayOptions(groupBy: .status),
      SessionDisplayOptions(groupBy: .updated), SessionDisplayOptions(groupBy: .created),
      SessionDisplayOptions(groupBy: .harness), SessionDisplayOptions(sortBy: .created),
      SessionDisplayOptions(show: .mine),
    ])
  func keptStateMatchesAFreshBuild(_ display: SessionDisplayOptions) {
    let list = SidebarBenchmarks.list(8)
    let memo = SidebarStateMemo()
    for change in Self.ownChanges + Self.moves {
      change.apply(list)
      let kept = memo.state(list: list, display: display, server: nil)
      #expect(
        kept == SidebarAdapter.state(list: list, display: display, server: nil),
        "after \(change.step)")
      // The rows and counts a live reader gives are the ones this state holds.
      let live = SidebarAdapter.live(list)
      for session in kept.list.sessions {
        #expect(live.row(session.id, true) == kept.rowContent(session), "after \(change.step)")
      }
      #expect(live.counts() == kept.counts, "after \(change.step)")
    }
  }

  @Test("The list's reader is told when a row moves, not when a session says something new")
  func readerIsToldOfMoves() {
    let list = SidebarBenchmarks.list(8)
    let memo = SidebarStateMemo()
    let reads = { _ = memo.state(list: list, display: SessionDisplayOptions(), server: nil) }
    reads()
    for change in Self.ownChanges {
      #expect(!observationNotifies(reads) { change.apply(list) }, "\(change.step) told the list")
    }
    reads()
    #expect(memo.builds == 1 + Self.ownChanges.count, "each change is in the next state read")
    for change in Self.moves {
      #expect(observationNotifies(reads) { change.apply(list) }, "\(change.step) was not told")
    }
  }

  @Test("Grouped by status, a row that changes group is told to the list; its text is not")
  func statusGroupingFollowsRows() {
    let list = SidebarBenchmarks.list(8)
    let memo = SidebarStateMemo()
    let display = SessionDisplayOptions(groupBy: .status)
    let reads = { _ = memo.state(list: list, display: display, server: nil) }
    reads()
    let told: (String) -> Bool = { step in
      let change = Self.ownChanges.first { $0.step == step }
      return observationNotifies(reads) { change?.apply(list) }
    }
    #expect(!told("a preview"))
    #expect(!told("a title"))
    #expect(told("a read mark"), "Done to Unread")
    #expect(told("a draft"), "Done to Draft")
    #expect(told("a status"), "Done to Working")
    #expect(told("a request"), "Working to Needs attention")
    #expect(
      !observationNotifies(reads) {
        list.apply(
          Self.row(3) {
            $0.status = .needsResponse
            $0.pendingRequests = 1
          })
      },
      "it stays under Needs attention")
  }

  /// Three sessions the core keeps in one order while the second one's update goes from a
  /// minute ago to ten days ago.
  private static func datedSessions(secondUpdated secondsAgo: Int64 = 60) -> [OmnigentCoreFFI
    .SessionSummary]
  {
    let now = Int64(Date().timeIntervalSince1970)
    let day: Int64 = 86_400
    var rows = SidebarBenchmarks.sessions(3)
    rows[0].updatedAt = now
    rows[1].updatedAt = now - secondsAgo
    rows[2].updatedAt = now - 40 * day
    return rows
  }

  @Test("Grouped by update, an update that keeps the core's order can still change a row's group")
  func updateGroupingFollowsRows() {
    let list = SidebarBenchmarks.list(3)
    list.apply(.reset(sessions: Self.datedSessions()))
    let memo = SidebarStateMemo()
    let display = SessionDisplayOptions(groupBy: .updated)
    let reads = { _ = memo.state(list: list, display: display, server: nil) }
    reads()
    let placement = list.placementRevision
    var talks = Self.datedSessions()[1]
    talks.preview = "A new message"
    #expect(!observationNotifies(reads) { list.apply(.upsert(sessions: [talks])) })
    let older = Self.datedSessions(secondUpdated: 10 * 86_400)[1]
    #expect(observationNotifies(reads) { list.apply(.upsert(sessions: [older])) })
    #expect(list.placementRevision == placement, "the core's order did not change")
    #expect(
      memo.state(list: list, display: display, server: nil)
        == SidebarAdapter.state(list: list, display: display, server: nil))
  }

  @Test(
    "Where rows are not placed by what they say, the same update is the row's alone",
    arguments: [
      SessionDisplayOptions(), SessionDisplayOptions(groupBy: .harness),
      SessionDisplayOptions(groupBy: .created), SessionDisplayOptions(sortBy: .created),
    ])
  func otherOrdersDoNotFollowRows(_ display: SessionDisplayOptions) {
    let list = SidebarBenchmarks.list(3)
    list.apply(.reset(sessions: Self.datedSessions()))
    let memo = SidebarStateMemo()
    let reads = { _ = memo.state(list: list, display: display, server: nil) }
    reads()
    let older = Self.datedSessions(secondUpdated: 10 * 86_400)[1]
    #expect(!observationNotifies(reads) { list.apply(.upsert(sessions: [older])) })
    #expect(
      memo.state(list: list, display: display, server: nil)
        == SidebarAdapter.state(list: list, display: display, server: nil))
  }

  @Test("A memo that reads another list follows that one and forgets the first")
  func followsTheListItReads() {
    let first = SidebarBenchmarks.list(8)
    let second = SidebarBenchmarks.list(3)
    let memo = SidebarStateMemo()
    let display = SessionDisplayOptions(groupBy: .status)
    #expect(memo.state(list: first, display: display, server: nil).list.sessions.count == 8)
    let reads = { _ = memo.state(list: second, display: display, server: nil) }
    reads()
    #expect(memo.builds == 2)
    #expect(!observationNotifies(reads) { first.apply(Self.row(3) { $0.status = .running }) })
    reads()
    #expect(memo.builds == 2, "the first list's change is not this state's")
    #expect(observationNotifies(reads) { second.apply(Self.row(1) { $0.status = .running }) })
    #expect(memo.state(list: second, display: display, server: nil).list.sessions.count == 3)
    #expect(memo.builds == 3)
  }

  @Test("A row's reader is told of its own session, and of its draft only where it shows one")
  func liveRowReadsItsOwnSession() {
    let list = SidebarBenchmarks.list(4)
    let live = SidebarAdapter.live(list)
    #expect(live.row("gone", true) == nil)
    let shown = { _ = live.row("s1", true) }
    let open = { _ = live.row("s1", false) }
    #expect(!observationNotifies(shown) { list.apply(Self.row(2) { $0.preview = "Other" }) })
    #expect(observationNotifies(shown) { list.apply(Self.row(1) { $0.preview = "Mine" }) })
    #expect(live.row("s1", true)?.session.preview == "Mine")
    #expect(!observationNotifies(open) { list.setDraft("s1", true) }, "its row hides the mark")
    #expect(live.row("s1", false)?.info.hasDraft == false)
    #expect(live.row("s1", true)?.info.hasDraft == true)
    #expect(observationNotifies(shown) { list.setDraft("s1", false) })
    #expect(!observationNotifies(shown) { list.unreadIDs = ["s2"] })
    #expect(observationNotifies(shown) { list.unreadIDs = ["s1", "s2"] })
    #expect(live.row("s1", true)?.isUnread == true)
    let asks = Self.row(1) {
      $0.status = .needsResponse
      $0.pendingRequests = 2
    }
    let counts = { _ = live.counts() }
    #expect(!observationNotifies(counts) { list.apply(Self.row(2) { $0.preview = "Again" }) })
    #expect(observationNotifies(counts) { list.apply(asks) })
    #expect(live.row("s1", true)?.requests == 2)
    #expect(live.row("s2", true)?.requests == nil)
    #expect(live.counts() == SidebarCounts(inbox: 1, filters: [.running: 0, .needsResponse: 1]))
  }
}
