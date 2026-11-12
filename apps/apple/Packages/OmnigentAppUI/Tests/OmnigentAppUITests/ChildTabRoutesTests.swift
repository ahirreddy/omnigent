import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import OmnigentUIComponents
import OmnigentViewTesting
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

// What a side chat's or sub-agent's tab does once it is in its parent's strip.
extension ChildTabsTests {
  private func childSection(_ id: String, name: String) -> OmnigentCoreFFI.EventSection {
    OmnigentCoreFFI.EventSection(
      id: "child-\(id)", title: name, summary: "Running", details: [], sessionId: id)
  }

  @Test("A sub-agent's own tabs and links open beside it, never as a session of their own")
  func childTabsStayInTheParentsStrip() async throws {
    let window = try await window()
    let groups = window.session.tabs
    let group = window.group
    window.tabs.openChild("conv_child", from: "conv_a", in: "conv_a")
    let child = try #require(group.selected)
    #expect(child.content == .subagent(parentID: "conv_a", childID: "conv_child"))
    let routes = window.tabs.routes(for: "conv_child", in: "conv_a")

    routes.openTerminal("term_1")
    let terminal = try #require(group.selected)
    #expect(terminal.content == .terminal(sessionID: "conv_child", terminalID: "term_1"))
    // Show Chat on its terminal goes back to its tab.
    window.tabs.showConversation("conv_child", fromTab: terminal.id)
    #expect(group.selectedID == child.id)

    routes.openSideChat("row_1", "Why?")
    #expect(group.selected?.content == .sideChat(sessionID: "conv_child", rowID: "row_1"))
    #expect(group.selected?.title == "Why?")
    let openBrowser = try #require(routes.openBrowser)
    openBrowser()
    #expect(group.selected?.content.kind == .browser)
    #expect(group.tabs.count == 5)

    // A link clicked in it opens in the other pane of the same strip.
    group.select(child.id)
    let address = try #require(URL(string: "https://example.com/a"))
    window.tabs.openLinkBeside(address, from: "conv_child", in: "conv_a")
    let page = try #require(group.selected)
    #expect(group.pane(of: page.id) == .trailing)
    #expect(group.pane(of: child.id) == .leading)
    #expect(group.split?.otherSelectedID == child.id, "the sub-agent still shows in its pane")

    // Its parent link shows the parent's chat; a session that is not under it shows as itself.
    routes.openSession("conv_a")
    #expect(group.selected?.content == .chat(sessionID: "conv_a"))
    #expect(groups.page == .session("conv_a"))
    #expect(groups.groups["conv_child"] == nil, "nothing made the sub-agent a window session")
    routes.openSession("conv_b")
    #expect(groups.page == .session("conv_b"))
  }

  @Test("A sub-agent's sub-agent opens in the same strip; the tree's other sessions do not")
  func deeperChildren() async throws {
    let core = try await ConversationFixtures.core()
    let parent = ConversationStore(sessionID: "p", core: core)
    let child = ConversationStore(sessionID: "c", core: core)
    parent.apply(
      revision: 1,
      change: TranscriptChange(
        rows: [], header: nil, sections: [childSection("c", name: "Explore auth")]))
    child.apply(
      revision: 1,
      change: TranscriptChange(rows: [], header: nil, sections: [childSection("g", name: "Grep")]))
    #expect(parent.listedChildren.map(\.id) == ["c"])
    let known = KnownChildren([parent, child])
    #expect(known.names == ["c": "Explore auth", "g": "Grep"])
    #expect(known.runs("c", under: "p") { _ in nil })
    #expect(known.runs("g", under: "p") { _ in nil })
    #expect(!known.runs("p", under: "c") { _ in nil })
    #expect(!known.runs("other", under: "p") { _ in nil })
    // The session list supplies a link the conversations did not report.
    #expect(known.runs("listed", under: "p") { $0 == "listed" ? "c" : nil })
    // A parent link that loops ends the walk.
    #expect(!known.runs("x", under: "p") { $0 == "x" ? "y" : "x" })
  }

  @Test("With sub-agents in their own window, one opens there unless its tab is already open")
  func subagentsApart() async throws {
    var window = try await window()
    final class Windows { var sessions: [String] = [] }
    let windows = Windows()
    window.tabs.openInNewWindow = { windows.sessions.append($0) }
    try await window.reportChild("conv_child")
    let apart = window.tabs.routes(for: "conv_a", subagentsApart: true)
    // The agent list follows the setting as the transcript's rows do.
    apart.openSession("conv_child")
    apart.openChild?("conv_child")
    #expect(windows.sessions == ["conv_child", "conv_child"])
    #expect(window.group.tabs.count == 1)

    window.tabs.routes(for: "conv_a", subagentsApart: false).openChild?("conv_child")
    let tab = try #require(window.group.selected)
    window.group.select(try #require(window.group.tabs.first).id)
    apart.openChild?("conv_child")
    #expect(windows.sessions.count == 2, "its open tab is focused instead")
    #expect(window.group.selectedID == tab.id)
  }

  @Test("A /side the server refuses awaits nothing; only a typed question forks")
  func unsentSideChat() async throws {
    let window = try await window(sendStatus: 400)
    let conversation = window.conversation
    conversation.composer.text = "/side why?"
    #expect(SessionToolsAdapter.sendsForkingSideChat(conversation))
    await SessionToolsAdapter.send(conversation, newSession: nil, routes: window.chat.toolRoutes)
    #expect(conversation.composer.lastError != nil)
    #expect(!window.session.forkedSideChats.isAwaiting("conv_a"))
    #expect(conversation.composer.text == "/side why?", "the refused command is back in the field")
    try await window.reportChild("conv_worker")
    #expect(window.group.tabs.count == 1, "a later sub-agent is not taken for the side chat")

    for draft in ["/side", "/side   ", "/sidebar now", "why /side this"] {
      conversation.composer.text = draft
      #expect(!SessionToolsAdapter.sendsForkingSideChat(conversation), "\(draft)")
    }
    // A tagged path goes ahead of the text, which is then an ordinary message.
    conversation.composer.text = "/side why?"
    conversation.composer.mentions = ["notes.md"]
    #expect(!SessionToolsAdapter.sendsForkingSideChat(conversation))
    // An agent whose side chats fork on the server is sent no `/side`.
    let other = try await ConversationFixtures.store(
      header: ConversationFixtures.header(settings: ConversationFixtures.settings()))
    other.composer.text = "/side why?"
    #expect(!SessionToolsAdapter.sendsForkingSideChat(other))
  }

  @Test("Forks pair with their waits oldest first; a withdrawn or closed wait takes none")
  func forkWaits() async throws {
    let window = try await window()
    let forks = window.session.forkedSideChats
    final class Log { var events: [String] = [] }
    let log = Log()
    let conversation = window.conversation
    func wait(_ name: String) -> ForkedSideChats.WaitID {
      forks.awaitFork(
        of: conversation, gaveUp: { log.events.append("\(name) gave up") },
        forked: { log.events.append("\(name)=\($0)") })
    }
    // A child the session already had is nobody's fork.
    try await window.reportChild("conv_first")
    let withdrawn = wait("a")
    _ = wait("b")
    _ = wait("c")
    forks.cancel(withdrawn, of: "conv_a")
    try await window.reportChild("conv_one")
    try await eventually("the first fork") { log.events == ["b=conv_one"] }
    #expect(forks.isAwaiting("conv_a"))
    try await window.reportChild("conv_two")
    try await eventually("the second fork") { log.events == ["b=conv_one", "c=conv_two"] }
    #expect(!forks.isAwaiting("conv_a"), "nothing is watched once every wait has its fork")

    // A session that closes can no longer report a fork: its waits give up, told.
    _ = wait("d")
    window.session.close("conv_a")
    #expect(log.events.last == "d gave up")
    #expect(!forks.isAwaiting("conv_a"))
  }

  @Test("A fork that is never reported gives up, and a late one is then nobody's")
  func forkNeverReported() async throws {
    let window = try await window()
    let forks = window.session.forkedSideChats
    forks.patience = .milliseconds(50)
    final class Log { var events: [String] = [] }
    let log = Log()
    forks.awaitFork(
      of: window.conversation, gaveUp: { log.events.append("gave up") },
      forked: { log.events.append($0) })
    try await eventually("the wait to give up") { log.events == ["gave up"] }
    #expect(!forks.isAwaiting("conv_a"))
    try await window.reportChild("conv_late")
    #expect(log.events == ["gave up"])

    // A typed /side whose fork never comes tells the window, and opens no tab.
    final class Failures { var messages: [String] = [] }
    let failures = Failures()
    let tabs = WindowTabs(
      session: window.session, context: TabWindowContext(), showAll: {},
      fail: { failures.messages.append($0) })
    #expect(tabs.awaitForkedSideChat(of: "conv_a", in: "conv_a") != nil)
    try await eventually("the window to be told") { failures.messages.count == 1 }
    #expect(failures.messages.first?.contains("didn't report a side chat") == true)
    #expect(window.group.tabs.count == 1)
    #expect(tabs.awaitForkedSideChat(of: "conv_closed", in: "conv_a") == nil, "not open")
  }

  @Test("A sub-agent's tab is titled by its name, else its session, and shows it working")
  func subagentTabItem() async throws {
    let window = try await window()
    let session = window.session
    let unnamed = AppTab(content: .subagent(parentID: "conv_b", childID: "conv_gone"))
    var item = TabAdapter.item(unnamed, session: session, browser: nil)
    #expect(item.title == "Sub-agent", "never the parent's title")
    #expect(item.kind == .chat)
    #expect(item.isClosable && !item.canDuplicate && !item.leadsGroup)
    #expect(item.groupID == "conv_b")
    let named = AppTab(
      content: .subagent(parentID: "conv_b", childID: "conv_a"), title: "Explore auth")
    item = TabAdapter.item(named, session: session, browser: nil)
    #expect(item.title == "Explore auth")
    #expect(TabAdapter.cachedTitle(named, session: session, browser: nil) == "Explore auth")
    #expect(item.status == .none)
    let header = try #require(window.conversation.header)
    window.conversation.apply(
      revision: 99,
      change: TranscriptChange(
        rows: [],
        header: SessionHeader(
          id: header.id, title: header.title, status: .running, readOnly: false,
          archived: false, permissionLevel: 4, failureMessage: nil, settings: header.settings),
        sections: nil))
    #expect(TabAdapter.item(named, session: session, browser: nil).status == .running)
    // The tab keeps both sessions open and counts as a conversation that stays built.
    #expect(named.content.openSessionIDs == ["conv_b", "conv_a"])
    #expect(named.content.conversationID == "conv_a")
    #expect(named.content.focusesExisting && named.content.destination == nil)
    var places = KeptPlaces(conversations: 1)
    let staysBuilt = places.take(named.content)
    #expect(staysBuilt)
    #expect(!WindowTabs.offersTerminal(named.content))
  }

  @Test("Saved side chat and sub-agent tabs restore in their parent's strip, with their tabs")
  func restoredChildTabs() throws {
    let chat = AppTab(content: .chat(sessionID: "p"))
    let side = AppTab(content: .sideChatSession(parentID: "p", childID: "side"))
    let agent = AppTab(content: .subagent(parentID: "p", childID: "c"), title: "Explore auth")
    let shell = AppTab(content: .terminal(sessionID: "c", terminalID: "t1"))
    // Tabs of sessions that have no tab here do not belong, nor does a second primary chat.
    let stray = AppTab(content: .terminal(sessionID: "other", terminalID: "t2"))
    let otherChat = AppTab(content: .chat(sessionID: "c"))
    let elsewhere = AppTab(content: .subagent(parentID: "other", childID: "x"))
    let saved = TabWindowSnapshot(
      tabs: [chat, side, agent, shell, stray, otherChat, elsewhere], selectedID: agent.id)
    let data = try JSONEncoder.tabs.encode(TabGroupRecord(savedAt: .now, snapshot: saved))
    let read = try JSONDecoder.tabs.decode(TabGroupRecord.self, from: data)
    #expect(read.skipped.isEmpty)
    #expect(read.snapshot == saved)

    let groups = SessionTabGroups()
    groups.loadSaved = { $0 == "p" ? read.snapshot : nil }
    groups.show(.session("p"))
    let group = try #require(groups.current)
    #expect(group.tabs == [chat, side, agent, shell])
    #expect(group.selected == agent)
    #expect(groups.liveSessionIDs == ["p", "c"], "only the shown tab's sessions open")
    #expect(!SessionTabGroups.isDefault(group.snapshot), "worth saving again")
    // Opening the restored sub-agent or side chat again focuses its tab.
    #expect(group.open(.subagent(parentID: "p", childID: "c")).id == agent.id)
    #expect(group.open(.sideChatSession(parentID: "p", childID: "side")).id == side.id)
    #expect(group.tabs.count == 4)
  }

  @Test("A sub-agent's tab shows its chat in the parent's window, which stays on the parent")
  func mountedSubagentTab() async throws {
    let mounted = try await ConnectedWindowFlowTests().mounted()
    defer { mounted.screen.close() }
    let session = mounted.session
    mounted.view.windowTabs.openChild("conv_b", from: "conv_a", in: "conv_a")
    try await settle(mounted.screen, until: "the sub-agent's conversation") {
      session.connection.openConversation("conv_b") != nil
    }
    try await pause(mounted.screen, .milliseconds(200))
    #expect(mounted.selection.page == .session("conv_a"))
    #expect(session.tabs.page == .session("conv_a"))
    #expect(session.tabs.groups["conv_b"] == nil)
    let shown = try #require(session.tabs.current?.selected)
    #expect(shown.content == .subagent(parentID: "conv_a", childID: "conv_b"))
  }
}
