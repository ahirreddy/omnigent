import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

#if os(macOS)
  import OmnigentDesktop
#endif

@MainActor
@Suite("One needs-you signal across the sidebar, Inbox, badge and menu bar")
struct AttentionAdapterTests {
  private func demoStore() async throws -> ConnectionStore {
    let store = try await PreviewData.connectedDemoStore()
    let deadline = ContinuousClock.now + .seconds(10)
    while store.sessionList.sessionsByID.count < 3, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(store.sessionList.sessionsByID.count == 3)
    return store
  }

  @Test(.timeLimit(.minutes(1))) func everySurfaceShowsTheSameCount() async throws {
    let store = try await demoStore()
    let list = store.sessionList
    let needing = Int(list.attentionTotals.sessionsNeedingYou)
    #expect(needing == 2)

    let sidebar = SidebarAdapter.state(
      list: list, display: SessionDisplayOptions(), server: store.connectedServer)
    #expect(sidebar.list.filterCounts[.needsResponse] == needing)
    #expect(sidebar.inboxCount == needing)
    #expect(sidebar.list.filterCounts[.running] == Int(list.attentionTotals.working))
    #expect(sidebar.list.sessions.count { $0.attention == .needsYou } == needing)
    #expect(sidebar.list.attentionCounts == ["demo-design": 1, "demo-question": 1])
    #expect(sidebar.list.sessions.first { $0.id == "demo-notes" }?.attention == .idle)

    #expect(InboxAdapter.state(list: list).needsYouCount == needing)
    #expect(store.notifications?.badgeCount == needing)

    #if os(macOS)
      let menuBar = MenuBarSessions()
      let server = try #require(URL(string: "http://127.0.0.1:6767"))
      menuBar.register(store, serverURL: server, instance: UUID())
      // A second window on the same server counts once.
      menuBar.register(store, serverURL: server, instance: UUID())
      #expect(menuBar.unreadCount == needing)
      #expect(
        menuBar.sessionsNeedingAttention.filter { $0.reason == .awaitingInput }.count == needing)
    #endif
  }
}
