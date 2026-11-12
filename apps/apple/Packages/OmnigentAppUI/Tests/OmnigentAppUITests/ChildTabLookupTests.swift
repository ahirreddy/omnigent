import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

// Where a link to a session lands when its tab, or what is known of it, is already there.
extension ChildTabsTests {
  @Test("A sub-agent only the Agents tab's tree lists joins its parent's strip, under its name")
  func childrenFromTheAgentTree() async throws {
    let window = try await window()
    let reviewer =
      #"{"id":"conv_tree","busy":false,"tool":"explorer","session_name":"reviewer"}"#
    window.server.route(
      "/v1/sessions/conv_a/child_sessions",
      .json(#"{"object":"list","data":[\#(reviewer)],"has_more":false}"#))
    window.server.route(
      "/v1/sessions/conv_tree/child_sessions",
      .json(#"{"object":"list","data":[],"has_more":false}"#))
    let tools = window.conversation.tools
    await tools.loadAgentTree()
    let tree = try #require(tools.agentTree, "\(String(describing: tools.agentTreeError))")
    let node = try #require(tree.nodes.first { $0.sessionId == "conv_tree" })
    #expect(window.conversation.listedChildren.isEmpty, "the stream reported no child")

    let known = KnownChildren([window.conversation])
    #expect(known.parents == ["conv_tree": "conv_a"], "the tree's root has no parent")
    #expect(known.names["conv_tree"] == node.name)
    #expect(known.runs("conv_tree", under: "conv_a") { _ in nil })

    // A link to it from the parent's chat opens a tab beside the chat, not a session.
    window.tabs.routes(for: "conv_a", subagentsApart: false).openSession("conv_tree")
    #expect(window.group.selected?.content == .subagent(parentID: "conv_a", childID: "conv_tree"))
    #expect(window.strip.last?.title == node.name)
    #expect(window.session.tabs.page == .session("conv_a"))
    #expect(window.session.tabs.groups["conv_tree"] == nil)
  }

  @Test("Show Chat on a session's own terminal goes back to its chat, whatever tab asked")
  func showChatOfTheSessionItself() async throws {
    let window = try await window()
    let group = window.group
    let chat = try #require(group.selected)
    let terminal = group.open(.terminal(sessionID: "conv_a", terminalID: "term_1"), title: "zsh")
    group.select(terminal.id)
    window.tabs.showConversation("conv_a", fromTab: terminal.id)
    #expect(group.selectedID == chat.id)

    // The tab that asked has closed meanwhile: the session's chat shows all the same.
    group.select(terminal.id)
    window.tabs.showConversation("conv_a", fromTab: "tab_closed")
    #expect(group.selectedID == chat.id)
    #expect(group.tabs.count == 2)
    #expect(window.session.tabs.page == .session("conv_a"))
  }

  @Test("A typed /side whose fork is already open from the agent list shows that tab, once")
  func typedSideChatAlreadyOpen() async throws {
    let window = try await window()
    let group = window.group
    let conversation = window.conversation
    let chat = try #require(group.selected)
    conversation.composer.text = "/side why is the build slow?"
    await SessionToolsAdapter.send(conversation, newSession: nil, routes: window.chat.toolRoutes)
    let forks = window.session.forkedSideChats
    #expect(forks.isAwaiting("conv_a"))

    // The user opens the fork from the agent list before the chat is told of it.
    let listed = group.open(.subagent(parentID: "conv_a", childID: "conv_side"))
    group.select(chat.id)
    try await window.reportChild("conv_side", agent: "Side chat")
    try await eventually("the wait to end") { !forks.isAwaiting("conv_a") }
    #expect(group.selectedID == listed.id, "the open tab shows")
    #expect(group.tabs.count == 2, "no second tab for the same side chat")
  }
}
