import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

// A new side chat of a session whose agent forks its side chats itself (Codex): the tab's first
// message is asked of the parent's agent, and the tab becomes the fork the parent reports.
extension ChildTabsTests {
  /// Opens a new side chat of `conv_a` from its chat's Side chat control and types `question`.
  private func pendingTab(_ window: Window, question: String) throws -> AppTab {
    let start = try #require(
      SessionToolsAdapter.sideChat(window.conversation, routes: window.chat.toolRoutes))
    start()
    let tab = try #require(window.group.selected)
    #expect(tab.content == .sideChatSession(parentID: "conv_a", childID: nil))
    window.session.sideChatDrafts.update(tab.id) { $0.text = question }
    return tab
  }

  private func send(_ window: Window, _ tab: AppTab) {
    PendingSideChatTab.start(
      session: window.session, tabID: tab.id, parentID: "conv_a", fail: { _ in })
  }

  /// The text of each message posted to `conv_a`, in order.
  private func textsSent(_ window: Window) -> [String] {
    let bodies: [[String: Any]]
    do {
      bodies = try window.server.posted("/v1/sessions/conv_a/events")
    } catch {
      Issue.record("a message posted to conv_a has no JSON body: \(error)")
      return []
    }
    return bodies.compactMap { body in
      let data = body["data"] as? [String: Any]
      let content = data?["content"] as? [[String: Any]]
      return content?.first?["text"] as? String
    }
  }

  private func isPending(_ tab: AppTab, in window: Window) -> Bool {
    window.group.tab(tab.id)?.content == .sideChatSession(parentID: "conv_a", childID: nil)
  }

  private func shows(_ childID: String, in tab: AppTab, of window: Window) -> Bool {
    window.group.tab(tab.id)?.content == .sideChatSession(parentID: "conv_a", childID: childID)
  }

  @Test("Side chat opens a tab; its first message asks the parent's agent, and the tab is the fork")
  func pendingTabBecomesTheFork() async throws {
    let window = try await window()
    let (session, group, conversation) = (window.session, window.group, window.conversation)
    conversation.composer.text = "half a thought"
    let tab = try pendingTab(window, question: "why is the build slow?")
    #expect(group.tabs.count == 2)
    #expect(conversation.composer.text == "half a thought", "the main composer is not touched")

    send(window, tab)
    let waiting = session.sideChatDrafts.draft(tab.id)
    #expect(waiting.asked == "why is the build slow?", "the question shows as sent")
    #expect(waiting.isStarting && waiting.text.isEmpty && waiting.failure == nil)
    try await eventually("the question to reach the parent") {
      textsSent(window) == ["/side why is the build slow?"]
    }
    #expect(window.server.requests("POST", "/v1/sessions/conv_a/fork").isEmpty)
    #expect(isPending(tab, in: window), "it waits for the agent's fork")

    try await window.reportChild("conv_side", agent: "Side chat")
    try await eventually("the tab to show the fork") { shows("conv_side", in: tab, of: window) }
    #expect(group.tabs.count == 2, "the same tab, not a second one")
    #expect(group.selectedID == tab.id)
    #expect(window.strip.last?.title == "Side chat 1")
    #expect(session.sideChatDrafts.drafts[tab.id] == nil)
    #expect(!session.forkedSideChats.isAwaiting("conv_a"))
    // The parent's chat shows no message for it, and its draft is as it was.
    #expect(conversation.pendingMessages.rows.isEmpty)
    #expect(!conversation.displayRows.contains { $0.text.contains("/side") })
    #expect(conversation.composer.text == "half a thought")
    #expect(conversation.composer.lastError == nil && !conversation.composer.isBlocked)
    // What is typed in the tab from now on goes to the fork.
    #expect(group.tab(tab.id)?.content.conversationID == "conv_side")
    #expect(textsSent(window).count == 1)
    try await window.reportChild("conv_later")
    #expect(group.tabs.count == 2, "a later sub-agent is not a side chat")
  }

  @Test("A question the server refuses comes back to the tab's composer with the reason")
  func refusedQuestionIsKept() async throws {
    let window = try await window(sendStatus: 400)
    let drafts = window.session.sideChatDrafts
    let tab = try pendingTab(window, question: "why?")
    send(window, tab)
    try await eventually("the refusal") { drafts.draft(tab.id).failure != nil }
    let draft = drafts.draft(tab.id)
    #expect(draft.failure?.hasPrefix("Couldn't start a side chat for this session") == true)
    #expect(draft.text == "why?")
    #expect(draft.asked == nil && !draft.isStarting)
    #expect(!window.session.forkedSideChats.isAwaiting("conv_a"))
    try await window.reportChild("conv_worker")
    #expect(isPending(tab, in: window), "a later sub-agent is not taken for the side chat")
    #expect(window.conversation.pendingMessages.rows.isEmpty)
  }

  @Test("A fork the agent reports late still opens in its tab, which says it is still waiting")
  func lateForkOpensInItsTab() async throws {
    let window = try await window()
    let drafts = window.session.sideChatDrafts
    window.session.forkedSideChats.patience = .milliseconds(200)
    let tab = try pendingTab(window, question: "why?")
    send(window, tab)
    drafts.update(tab.id) { $0.text = "and how?" }
    try await eventually("the wait to be late") { drafts.draft(tab.id).isLate }
    let draft = drafts.draft(tab.id)
    #expect(draft.asked == "why?" && draft.isStarting, "the question stays asked")
    #expect(draft.failure == nil && draft.text == "and how?")
    try await window.reportChild("conv_worker")
    #expect(isPending(tab, in: window), "a sub-agent started meanwhile is not the fork")

    try await window.reportSideChat("conv_late")
    try await eventually("the tab to show the fork") { shows("conv_late", in: tab, of: window) }
    #expect(window.group.tabs.count == 2)
    #expect(window.strip.last?.title == "Side chat 1")
    #expect(drafts.drafts[tab.id] == nil)
  }

  @Test("A conversation that closes before its fork is reported gives the question back")
  func closedSessionGivesTheQuestionBack() async throws {
    let window = try await window()
    let drafts = window.session.sideChatDrafts
    let tab = try pendingTab(window, question: "why?")
    send(window, tab)
    try await eventually("the question") { textsSent(window).count == 1 }
    window.session.close("conv_a")
    let draft = drafts.draft(tab.id)
    #expect(draft.failure?.contains("didn't report a side chat") == true)
    #expect(draft.text == "why?" && draft.asked == nil && !draft.isStarting && !draft.isLate)
  }

  @Test("A side chat whose tab closed while it waited opens in a tab of its own, behind")
  func forkOfAClosedTab() async throws {
    let window = try await window()
    let group = window.group
    let chat = try #require(group.tabs.first)
    let tab = try pendingTab(window, question: "why?")
    send(window, tab)
    try await eventually("the question") { textsSent(window).count == 1 }
    group.requestClose(tab.id)
    #expect(group.selectedID == chat.id)

    try await window.reportSideChat("conv_side")
    try await eventually("the side chat's tab") { group.tabs.count == 2 }
    #expect(group.tabs.last?.content == .sideChatSession(parentID: "conv_a", childID: "conv_side"))
    #expect(group.selectedID == chat.id, "it does not take the selection")
    #expect(!window.session.forkedSideChats.isAwaiting("conv_a"))
  }

  @Test("Two new side chats and a typed /side take the forks in the order they asked")
  func forksPairInOrder() async throws {
    let window = try await window()
    let (group, conversation) = (window.group, window.conversation)
    let first = try pendingTab(window, question: "one")
    let second = try pendingTab(window, question: "two")
    send(window, first)
    try await eventually("the first question") { textsSent(window) == ["/side one"] }
    send(window, second)
    try await eventually("the second question") { textsSent(window).count == 2 }
    conversation.composer.text = "/side three"
    await SessionToolsAdapter.send(conversation, newSession: nil, routes: window.chat.toolRoutes)
    #expect(textsSent(window) == ["/side one", "/side two", "/side three"])
    #expect(group.tabs.count == 3)

    try await window.reportChild("conv_one", agent: "Side chat")
    try await eventually("the first tab's fork") { shows("conv_one", in: first, of: window) }
    #expect(isPending(second, in: window))
    #expect(window.session.sideChatDrafts.draft(second.id).asked == "two")
    try await window.reportChild("conv_two", agent: "Side chat")
    try await eventually("the second tab's fork") { shows("conv_two", in: second, of: window) }
    #expect(group.tabs.count == 3, "the typed one has no tab until its fork")
    try await window.reportChild("conv_three", agent: "Side chat")
    try await eventually("the typed side chat's tab") { group.tabs.count == 4 }
    #expect(
      group.selected?.content == .sideChatSession(parentID: "conv_a", childID: "conv_three"))
    #expect(!window.session.forkedSideChats.isAwaiting("conv_a"))
    #expect(conversation.pendingMessages.rows.isEmpty)
  }

  @Test("A /side sent from the queue shows no message in the chat either; other messages do")
  func queuedSideCommandShowsNoMessage() async throws {
    let window = try await window()
    let conversation = window.conversation
    let composer = conversation.composer
    composer.text = "/side why?"
    composer.queueDraft()
    let queued = try #require(composer.queue.items.first?.id)
    await composer.sendQueuedNow(queued)
    #expect(textsSent(window) == ["/side why?"])
    #expect(conversation.pendingMessages.rows.isEmpty)
    // The server echoes an ordinary message, so it shows until then.
    composer.text = "hello"
    await composer.send()
    #expect(conversation.pendingMessages.rows.map(\.text) == ["hello"])
  }

  @Test("A fork already open from the agent list is shown there, and the new tab closes")
  func forkAlreadyOpen() async throws {
    let window = try await window()
    let group = window.group
    let tab = try pendingTab(window, question: "why?")
    send(window, tab)
    try await eventually("the question") { textsSent(window).count == 1 }
    // The user opens the fork from the agent list before the tab is told of it.
    let forks = window.session.forkedSideChats
    let listed = group.open(.subagent(parentID: "conv_a", childID: "conv_side"))
    group.select(tab.id)
    try await window.reportChild("conv_side", agent: "Side chat")
    try await eventually("the wait to end") { !forks.isAwaiting("conv_a") }
    #expect(group.tab(tab.id) == nil)
    #expect(group.selectedID == listed.id)
    #expect(group.tabs.count == 2)
  }
}
