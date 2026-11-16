import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentAppUI

/// A session's sub-agents and the side chats its agent forks, reached from its chat: each shows
/// in a tab of the session's strip, and the window stays on the session.
@MainActor
@Suite("Sub-agent and forked side chat tabs", .timeLimit(.minutes(1)))
struct ChildTabsTests {
  struct Window {
    let session: ServerSession
    var tabs: WindowTabs
    let server: AppServer
    let browser: FakeBrowserHost
    /// `conv_a`'s conversation, read from the server and fed by `stream`.
    let conversation: ConversationStore
    let stream: ByteSink

    var group: TabStore { session.tabs.group("conv_a") }

    /// The strip's tabs for `conv_a`.
    var strip: [TabItemState] {
      TabAdapter.state(group, session: session, browser: browser, issue: nil).tabs
    }

    /// The agent reports a new child of `conv_a` on its stream.
    func reportChild(_ childID: String, agent: String = "explorer") async throws {
      let event =
        #"{"type":"session.created","conversation_id":"conv_a","child_session_id":"\#(childID)","agent_id":"\#(agent)"}"#
      stream.chunk(bytes: Data("event: session.created\ndata: \(event)\n\n".utf8))
      let conversation = conversation
      try await eventually("the child \(childID)") {
        conversation.sections.contains { $0.sessionId == childID }
      }
    }

    /// The agent reports a side chat it forked under `conv_a`, as Codex lists its `/side` fork:
    /// a child whose summary names it "Side chat".
    func reportSideChat(_ childID: String) async throws {
      try await reportChild(childID, agent: "Side chat")
      let child =
        #"{"id":"\#(childID)","parent_session_id":"conv_a","title":"codex-native-ui-subagent:t","tool":"Side chat","created_at":2,"updated_at":2,"busy":true,"labels":{"omnigent.wrapper":"codex-native-ui-subagent","omnigent.codex_native.agent_nickname":"Side chat"}}"#
      let event =
        #"{"type":"session.child_session.updated","conversation_id":"conv_a","child_session_id":"\#(childID)","child":\#(child)}"#
      stream.chunk(bytes: Data("event: session.child_session.updated\ndata: \(event)\n\n".utf8))
      let conversation = conversation
      try await eventually("the side chat \(childID)") {
        conversation.listedChildren.contains { $0.id == childID && $0.isSideChat }
      }
    }

    /// `conv_a`'s chat as the window mounts it, routed to this window's tabs.
    var chat: ConversationContainer {
      ConversationContainer(
        conversation: conversation,
        summary: session.connection.sessionList.session("conv_a"), terminals: nil,
        workspace: nil, panel: nil, changedFilesRevision: { 0 },
        navigation: SessionCommandActions(), opener: ExternalURLOpener { _ in true },
        openSession: { _ in }, retry: {}, server: session.connection.connectedServer,
        tabRoutes: tabs.routes(for: "conv_a", subagentsApart: false))
    }
  }

  /// A window showing `conv_a`, a Codex session (its side chats are forked by the agent from a
  /// typed `/side`) whose messages the server accepts with `status`; `labels` is its labels'
  /// JSON object.
  func window(sendStatus: UInt16 = 202, labels: String = "{}") async throws -> Window {
    SystemSideEffects.install()
    let server = threeSessionServer()
    let row =
      #"{"id":"conv_a","status":"idle","created_at":1,"updated_at":30,"host_id":"mac","runner_id":"r1","runner_online":true,"host_online":true,"workspace":"/work/conv_a","permission_level":4,"harness":"codex-native","labels":\#(labels)}"#
    server.route("/v1/sessions/conv_a", .json(row))
    server.route("/v1/sessions/conv_a/items", .json(#"{"data":[],"has_more":false}"#))
    server.route(
      "/v1/sessions/conv_a/events", method: "POST",
      .json(#"{"queued":false}"#, status: sendStatus))
    let streams = FakeEventStreamTransport()
    let connection = try await signedInStore(server, streams: streams)
    try await eventually("the session list") { connection.sessionList.isLoaded }
    let session = ServerSession(connection: connection, opener: ExternalURLOpener { _ in true })
    let browser = FakeBrowserHost()
    let tabs = WindowTabs(
      session: session, context: TabWindowContext(browser: browser), showAll: {},
      fail: { _ in })
    session.tabs.show(.session("conv_a"))
    session.keepOpen(session.tabs.liveSessionIDs)
    let conversation = try #require(connection.openConversation("conv_a"))
    // The connection's own update stream may open first.
    var opened = await streams.waitForOpenedStream()
    while !opened.request.url.contains("/v1/sessions/conv_a/stream") {
      opened = await streams.waitForOpenedStream()
    }
    opened.sink.response(
      status: 200, headers: [HttpHeader(name: "Content-Type", value: "text/event-stream")])
    let heartbeat = #"event: session.heartbeat\#ndata: {"type":"session.heartbeat"}\#n\#n"#
    opened.sink.chunk(bytes: Data(heartbeat.utf8))
    try await eventually("the session's agent") {
      conversation.isHydrated && conversation.header?.settings?.harness == "codex-native"
    }
    return Window(
      session: session, tabs: tabs, server: server, browser: browser,
      conversation: conversation, stream: opened.sink)
  }

  @Test("A sub-agent opened from its parent's chat gets a tab in the parent's strip, once")
  func subagentOpensInItsParentsStrip() async throws {
    let window = try await window()
    let groups = window.session.tabs
    let group = window.group
    let chat = try #require(group.selected)
    try await window.reportChild("conv_child")
    #expect(group.tabs.count == 1, "a sub-agent nobody opened has no tab")

    // The inspector's agent list and the composer's tray open a sub-agent this way.
    let routes = window.tabs.routes(for: "conv_a", subagentsApart: false)
    routes.openSession("conv_child")
    #expect(groups.page == .session("conv_a"), "the window stays on the parent session")
    #expect(groups.groups["conv_child"] == nil, "the sub-agent is not a session of the window")
    #expect(group.tabs.count == 2)
    #expect(group.tabs.first?.id == chat.id, "the parent's chat keeps its tab")
    let tab = try #require(group.tabs.last)
    #expect(group.selectedID == tab.id)
    #expect(tab.content.openSessionIDs == ["conv_a", "conv_child"])
    #expect(groups.liveSessionIDs.contains("conv_child"), "its conversation is kept open")
    let item = try #require(window.strip.last)
    #expect(item.title == "explorer", "titled as the agent list names it, not as the parent")
    #expect(item.isClosable)
    #expect(item.groupID == "conv_a")

    // The transcript's sub-agent row opens the same tab again instead of another.
    group.select(chat.id)
    let openRow = try #require(window.chat.routed(ConversationActions()).openChild)
    openRow("conv_child")
    #expect(group.tabs.count == 2)
    #expect(group.selectedID == tab.id)
    #expect(groups.page == .session("conv_a"))

    // It closes like any tab, and the parent's chat shows again.
    group.requestClose(tab.id)
    #expect(group.tabs.map(\.id) == [chat.id])
    #expect(group.selectedID == chat.id)
  }

  @Test("A Codex side chat opened from the agent list, again after its tab closed, is Side chat 1")
  func sideChatReopenedFromTheAgentList() async throws {
    final class Windows { var sessions: [String] = [] }
    let windows = Windows()
    var window = try await window()
    window.tabs.openInNewWindow = { windows.sessions.append($0) }
    let group = window.group
    let chat = try #require(group.selected)
    try await window.reportSideChat("conv_side")
    try await window.reportChild("conv_worker")

    // A side chat stays in its parent's strip even where sub-agents open in windows.
    let routes = window.tabs.routes(for: "conv_a", subagentsApart: true)
    routes.openSession("conv_side")
    #expect(windows.sessions.isEmpty)
    let tab = try #require(group.selected)
    #expect(tab.content == .sideChatSession(parentID: "conv_a", childID: "conv_side"))
    #expect(window.strip.last?.title == "Side chat 1")
    #expect(window.strip.last?.kind == .sideChat)

    group.requestClose(tab.id)
    #expect(group.selectedID == chat.id)
    routes.openSession("conv_side")
    let reopened = try #require(group.selected)
    #expect(reopened.content == .sideChatSession(parentID: "conv_a", childID: "conv_side"))
    #expect(window.strip.map(\.title).last == "Side chat 1", "not named as a sub-agent")
    #expect(window.session.tabs.page == .session("conv_a"))

    // A sub-agent of the same session still opens as one.
    routes.openSession("conv_worker")
    #expect(windows.sessions == ["conv_worker"])
    window.tabs.routes(for: "conv_a", subagentsApart: false).openSession("conv_worker")
    #expect(group.selected?.content == .subagent(parentID: "conv_a", childID: "conv_worker"))
  }

  @Test("Move Tab to New Window on a sub-agent's tab opens it in a window and takes the tab away")
  func movingASubagentToAWindow() async throws {
    final class Windows { var sessions: [String] = [] }
    let windows = Windows()
    var window = try await window()
    window.tabs.openInNewWindow = { windows.sessions.append($0) }
    let group = window.group
    let chat = try #require(group.selected)
    try await window.reportChild("conv_child")
    window.tabs.routes(for: "conv_a", subagentsApart: false).openSession("conv_child")
    #expect(window.strip.map(\.canMoveToNewWindow) == [false, true])

    // The overview's rows carry each tab's menu, after the list's own first row.
    let strip = try #require(window.tabs.strip)
    let screen = OffscreenWindow(
      TabOverviewSheet(state: strip.state, actions: strip.actions) {}, width: 600, height: 600)
    defer { screen.close() }
    let title = "Move Tab to New Window"
    #expect(!menuTitles(try contextMenu(ofListRow: 1, in: screen)).contains(title))
    try screen.choose(title, in: try contextMenu(ofListRow: 2, in: screen))
    #expect(windows.sessions == ["conv_child"])
    #expect(group.tabs.map(\.id) == [chat.id], "the tab left this window")
    #expect(group.closed.isEmpty, "it moved: Reopen Closed Tab has nothing to bring back")
  }

  @Test("A /side typed to an agent that forks the side chat itself opens the fork in a tab")
  func forkedSideChatOpensATab() async throws {
    let window = try await window()
    let groups = window.session.tabs
    let group = window.group
    let chat = try #require(group.selected)
    // A sub-agent the agent started on its own is not a side chat.
    try await window.reportChild("conv_worker")
    #expect(group.tabs.count == 1)

    let conversation = window.conversation
    conversation.composer.text = "/side why is the build slow?"
    await SessionToolsAdapter.send(conversation, newSession: nil, routes: window.chat.toolRoutes)
    #expect(conversation.composer.lastError == nil)
    #expect(try window.server.posted("/v1/sessions/conv_a/events").count == 1, "sent as typed")
    #expect(group.tabs.count == 1, "nothing opens until the agent reports its fork")
    // The server never echoes the command, so the transcript shows no row for it.
    #expect(conversation.pendingMessages.rows.isEmpty)
    #expect(!conversation.displayRows.contains { $0.text.contains("/side") })
    #expect(conversation.composer.text.isEmpty)

    try await window.reportChild("conv_side", agent: "Side chat")
    try await eventually("the side chat's tab") { group.tabs.count == 2 }
    let tab = try #require(group.tabs.last)
    #expect(group.selectedID == tab.id, "the side chat shows")
    #expect(tab.content.openSessionIDs == ["conv_a", "conv_side"])
    #expect(tab.content.kind == .sideChat)
    #expect(window.strip.last?.title == "Side chat 1")
    #expect(groups.page == .session("conv_a"))
    #expect(groups.groups["conv_side"] == nil)

    // The agent list reaches the same side chat: its tab is focused, not doubled.
    group.select(chat.id)
    window.tabs.routes(for: "conv_a", subagentsApart: false).openSession("conv_side")
    #expect(group.tabs.count == 2)
    #expect(group.selectedID == tab.id)
    #expect(groups.page == .session("conv_a"))

    // One `/side` opens one tab: the next child the agent starts is a plain sub-agent.
    try await window.reportChild("conv_later")
    #expect(group.tabs.count == 2)
  }

  @Test("A /side queued while a turn runs opens its fork in a tab once it goes out")
  func queuedSideChatOpensATab() async throws {
    let window = try await window()
    let group = window.group
    let conversation = window.conversation
    let composer = conversation.composer
    let forks = window.session.forkedSideChats
    // As the chat does when the window shows it.
    SessionToolsAdapter.watchForks(conversation, routes: window.chat.toolRoutes)
    composer.text = "/side why is the build slow?"
    composer.queueDraft()
    #expect(!forks.isAwaiting("conv_a"), "nothing is asked of the agent yet")
    try await window.reportChild("conv_worker")
    #expect(group.tabs.count == 1, "a sub-agent started meanwhile is not its fork")

    await composer.drainQueue(isRunning: false)
    #expect(try window.server.posted("/v1/sessions/conv_a/events").count == 1)
    #expect(forks.isAwaiting("conv_a"))
    try await window.reportSideChat("conv_side")
    try await eventually("the side chat's tab") { group.tabs.count == 2 }
    #expect(group.selected?.content == .sideChatSession(parentID: "conv_a", childID: "conv_side"))
    #expect(window.strip.last?.title == "Side chat 1")
    #expect(conversation.pendingMessages.rows.isEmpty)
  }
}
