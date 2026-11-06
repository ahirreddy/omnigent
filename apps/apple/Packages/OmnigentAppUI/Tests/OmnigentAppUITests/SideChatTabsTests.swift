import Foundation
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
@Suite("Side chat tabs")
struct SideChatTabsTests {
  @Test("Each new side chat is its own tab with its draft, grouped under its session")
  func pendingTabs() throws {
    let session = try ServerSession.demo()
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    session.tabs.open(.chat(sessionID: "s1"))
    tabs.openPendingSideChat("s1", draft: "> why?\n\n", sendNow: false)
    let first = try #require(session.tabs.selected)
    tabs.openPendingSideChat("s1", draft: "", sendNow: false)
    let second = try #require(session.tabs.selected)
    #expect(first.id != second.id)
    #expect(first.content == .sideChatSession(parentID: "s1", childID: nil))
    #expect(session.sideChatDrafts.draft(first.id).text == "> why?\n\n")
    #expect(!session.sideChatDrafts.draft(first.id).isStarting)
    let group = try #require(session.tabs.current)
    let strip = TabAdapter.state(group, session: session, browser: nil, issue: nil).tabs
    #expect(strip.map(\.title).suffix(2) == ["Side chat 1", "Side chat 2"])
    #expect(strip.suffix(2).allSatisfy { $0.isClosable && $0.groupID == "s1" })
    #expect(strip.suffix(2).allSatisfy { $0.kind == .sideChat })
  }

  @Test("A started side chat keeps its tab and keeps its own session open")
  func startedTab() {
    let store = TabStore()
    store.open(.chat(sessionID: "s1"))
    let pending = store.open(.sideChatSession(parentID: "s1", childID: nil))
    #expect(store.liveSessionIDs == ["s1"])
    store.replace(pending.id, with: .sideChatSession(parentID: "s1", childID: "side"))
    #expect(store.selectedID == pending.id)
    #expect(store.liveSessionIDs == ["s1", "side"])
    // Opening a started side chat again focuses its tab.
    store.open(.chat(sessionID: "s1"))
    let again = store.open(.sideChatSession(parentID: "s1", childID: "side"))
    #expect(again.id == pending.id)
    // The side chat leaves with its session.
    store.removeSessions(["s1"])
    #expect(store.tabs.isEmpty)
  }

  @Test("A started side chat groups under its parent and keeps its own session open")
  func liveWithParent() throws {
    let groups = SessionTabGroups()
    groups.showChat("s1")
    let pending = try #require(groups.open(.sideChatSession(parentID: "s1", childID: nil)))
    groups.replace(pending.id, with: .sideChatSession(parentID: "s1", childID: "side"))
    #expect(groups.currentSessionID == "s1")
    #expect(groups.current?.selectedID == pending.id)
    #expect(groups.liveSessionIDs == ["s1", "side"])
  }
}
