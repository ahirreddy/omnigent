import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The sidebar with hundreds of sessions: its state is built once per list change, and how long
/// a build takes. Run the timings with
/// `OMNIGENT_BENCH=1 swift test --package-path apps/apple/Packages/OmnigentAppUI --filter SidebarBenchmarks`.
@Suite("Sidebar benchmarks")
@MainActor
struct SidebarBenchmarks {
  nonisolated static let isEnabled = ProcessInfo.processInfo.environment["OMNIGENT_BENCH"] != nil

  static let projects = (0..<6).map {
    ProjectSummary(id: "p\($0)", name: "Project \($0)", icon: nil)
  }

  /// `count` sessions, filed round-robin into six projects with every fifth unfiled, as
  /// `seed-large-fixtures.py` seeds them.
  static func sessions(_ count: Int) -> [OmnigentCoreFFI.SessionSummary] {
    (0..<count).map { index in
      OmnigentCoreFFI.SessionSummary(
        id: "s\(index)", title: "Fix the cache #\(index)", preview: "", status: .idle,
        pendingRequests: 0, isReadOnly: false, updatedAt: Int64(10_000 - index),
        workspace: "/Users/me/src/repo\(index % 9)", agentName: "mock-model", isPinned: false,
        isArchived: false, permissionLevel: 4, failureMessage: nil, canRename: true,
        canPin: true, canArchive: true, configuration: nil, terminalFirst: false,
        createdAt: Int64(5_000 - index), owner: "me",
        projectId: index % 5 == 4 ? nil : "p\(index % 6)", projectLabel: nil, canStop: false)
    }
  }

  static func list(_ count: Int) -> SessionListStore {
    let list = SessionListStore()
    list.viewerID = "me"
    list.projects = projects
    list.apply(.reset(sessions: sessions(count)))
    return list
  }

  @Test("the memo rebuilds the sidebar only when the list changes")
  func memoRebuildsOnChange() {
    let list = Self.list(40)
    let memo = SidebarStateMemo()
    let first = memo.state(list: list, display: SessionDisplayOptions(), server: nil)
    let again = memo.state(list: list, display: SessionDisplayOptions(), server: nil)
    #expect(memo.builds == 1)
    #expect(again == first)
    // A server row that changes nothing leaves the list's values, so nothing is rebuilt.
    list.apply(.upsert(sessions: [Self.sessions(40)[3]]))
    _ = memo.state(list: list, display: SessionDisplayOptions(), server: nil)
    #expect(memo.builds == 1)
    var renamed = Self.sessions(40)[3]
    renamed.title = "Renamed"
    list.apply(.upsert(sessions: [renamed]))
    let updated = memo.state(list: list, display: SessionDisplayOptions(), server: nil)
    #expect(memo.builds == 2)
    #expect(updated.list.sessions.contains { $0.title == "Renamed" })
    _ = memo.state(list: list, display: SessionDisplayOptions(groupBy: .status), server: nil)
    #expect(memo.builds == 3)
  }

  @Test("benchmark: sidebar state for 650 sessions", .enabled(if: isEnabled))
  func sidebarState() {
    let sessions = Self.sessions(650)
    let list = Self.list(650)
    let clock = ContinuousClock()
    func perCall(_ count: Int, _ body: (Int) -> Void) -> Duration {
      clock.measure { for index in 0..<count { body(index) } } / count
    }
    let built = perCall(20) { _ in
      _ = SidebarAdapter.state(list: list, display: SessionDisplayOptions(), server: nil)
    }
    let memo = SidebarStateMemo()
    _ = memo.state(list: list, display: SessionDisplayOptions(), server: nil)
    let reused = perCall(20) { _ in
      _ = memo.state(list: list, display: SessionDisplayOptions(), server: nil)
    }
    // What every server row cost before: the whole list through the core.
    let everyRow = perCall(20) { _ in
      _ = filterSessions(sessions: sessions, text: "", filter: .all)
      _ = sessions.map { sessionAttention(session: $0, isUnread: false) }
      _ = attentionTotals(sessions: sessions, unreadIds: [])
    }
    let unchanged = perCall(20) { _ in list.apply(.upsert(sessions: [sessions[10]])) }
    let changed = perCall(20) { index in
      var row = sessions[10]
      row.updatedAt = Int64(20_000 + index)
      list.apply(.upsert(sessions: [row]))
    }
    // The palette and Inbox read the sessions needing the user on every shell redraw.
    let needsYouRead = perCall(20) { _ in _ = list.needsResponse }
    let needsYouFiltered = perCall(20) { _ in
      _ = filterSessions(sessions: sessions, text: "", filter: .needsResponse)
    }
    print(
      "benchmark: 650 sessions; sidebar state built \(built), memo hit \(reused); "
        + "a server row through the whole list \(everyRow), now unchanged \(unchanged), "
        + "changed \(changed); needs-you read \(needsYouRead) (filtering every session "
        + "\(needsYouFiltered))")
  }
}
