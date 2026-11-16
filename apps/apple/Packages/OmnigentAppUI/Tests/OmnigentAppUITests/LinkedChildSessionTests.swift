import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

// A deep link or a notification that names a sub-agent or side chat opens it in the strip of
// the session it runs under, as the agent list does.
extension ChildTabsTests {
  @Test("A link to a sub-agent or side chat the window knows opens its tab in the parent's strip")
  func linkToAKnownChild() async throws {
    let window = try await window()
    let session = window.session
    let group = window.group
    try await window.reportChild("conv_child")
    try await window.reportSideChat("conv_side")
    session.tabs.show(.session("conv_b"))

    #expect(await session.showLinkedSession("conv_child") == .session("conv_a"))
    #expect(session.tabs.page == .session("conv_a"))
    #expect(session.tabs.groups["conv_child"] == nil, "not a session of its own")
    #expect(group.selected?.content == .subagent(parentID: "conv_a", childID: "conv_child"))
    #expect(window.strip.last?.title == "explorer")

    #expect(await session.showLinkedSession("conv_side") == .session("conv_a"))
    #expect(group.selected?.content == .sideChatSession(parentID: "conv_a", childID: "conv_side"))
    let count = group.tabs.count
    #expect(await session.showLinkedSession("conv_child") == .session("conv_a"))
    #expect(group.tabs.count == count, "its open tab is focused, not doubled")

    // A top-level session shows its own chat, with no agent tree read for it.
    #expect(await session.showLinkedSession("conv_b") == .session("conv_b"))
    #expect(session.tabs.selected?.content == .chat(sessionID: "conv_b"))
    #expect(window.server.requests("GET", "/v1/sessions/conv_b/child_sessions").isEmpty)
  }

  @Test("A link to a child the window has not seen finds where it runs from its agent tree")
  func linkToAnUnknownChild() async throws {
    let window = try await window()
    let session = window.session
    let server = window.server
    server.route(
      "/v1/sessions/conv_deep",
      .json(
        #"{"id":"conv_deep","status":"idle","created_at":2,"parent_session_id":"conv_a","root_conversation_id":"conv_a"}"#
      ))
    server.route(
      "/v1/sessions/conv_a/child_sessions",
      .json(
        #"{"object":"list","data":[{"id":"conv_deep","busy":false,"tool":"Side chat","labels":{"omnigent.wrapper":"codex-native-ui-subagent","omnigent.codex_native.agent_nickname":"Side chat"}}]}"#
      ))
    server.route(
      "/v1/sessions/conv_deep/child_sessions", .json(#"{"object":"list","data":[]}"#))
    session.tabs.show(.session("conv_b"))

    #expect(await session.showLinkedSession("conv_deep") == .session("conv_a"))
    #expect(session.tabs.page == .session("conv_a"))
    #expect(session.tabs.groups["conv_deep"] == nil)
    #expect(
      window.group.selected?.content
        == .sideChatSession(parentID: "conv_a", childID: "conv_deep"))

    // A session the server can't place still opens, as a session of its own.
    #expect(await session.showLinkedSession("conv_gone") == .session("conv_gone"))
    #expect(session.tabs.page == .session("conv_gone"))
  }
}
