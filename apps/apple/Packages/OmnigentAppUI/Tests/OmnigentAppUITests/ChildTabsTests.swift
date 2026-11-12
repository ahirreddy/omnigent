import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
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
  /// typed `/side`) whose messages the server accepts with `status`.
  func window(sendStatus: UInt16 = 202) async throws -> Window {
    SystemSideEffects.install()
    let server = threeSessionServer()
    let row =
      #"{"id":"conv_a","status":"idle","created_at":1,"updated_at":30,"host_id":"mac","runner_id":"r1","runner_online":true,"host_online":true,"workspace":"/work/conv_a","permission_level":4,"harness":"codex-native"}"#
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
}
