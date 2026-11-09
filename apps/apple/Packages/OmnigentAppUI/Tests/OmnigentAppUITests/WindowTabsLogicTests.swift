import Foundation
import OmnigentCoreFFI
import OmnigentRemoteBrowser
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

@MainActor
@Suite("Window tabs")
struct WindowTabsLogicTests {
  private func tabs(_ session: ServerSession, supportsSplit: Bool = true) -> WindowTabs {
    var tabs = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {}, fail: { _ in })
    tabs.supportsSplit = supportsSplit
    return tabs
  }

  @Test("A session-less page has no strip; New Tab goes to New Session")
  func sessionlessPage() throws {
    let session = try ServerSession.demo()
    let window = tabs(session)
    #expect(window.store == nil)
    #expect(window.strip == nil)
    let commands = window.commands
    // swiftlint:disable:next empty_count
    #expect(commands.count == 0)
    #expect(commands.closeTab == nil)
    #expect(commands.toggleSplit == nil)
    commands.selectTab(.max)
    commands.selectTab(.min)
    commands.newTab()
    #expect(window.store == nil)
  }

  @Test("A primary chat can't close; a second tab adds next and previous")
  func commandsFollowTheTabs() throws {
    let session = try ServerSession.demo()
    let window = tabs(session)
    session.tabs.open(.chat(sessionID: "s"))
    let single = window.commands
    #expect(single.count == 1)
    #expect(single.closeTab == nil)
    #expect(single.selectNextTab == nil)
    #expect(single.toggleTerminal != nil)
    #expect(single.supportsSplit)
    #expect(!single.isSplit)
    #expect(single.focusPane == nil)
    #expect(single.openBrowser == nil)

    single.newTab()
    let double = window.commands
    #expect(double.count == 2)
    #expect(double.closeTab != nil)
    #expect(double.selectNextTab != nil)
    #expect(double.toggleTerminal == nil)
    double.selectTab(.max)
    double.selectTab(.min)
    #expect(window.store?.tabs.count == 2)
    double.toggleSplit?()
    #expect(window.commands.isSplit)
    #expect(window.commands.focusPane != nil)
  }

  @Test("A narrow window offers no split")
  func narrowWindow() throws {
    let session = try ServerSession.demo()
    session.tabs.open(.chat(sessionID: "s"))
    let window = tabs(session, supportsSplit: false)
    #expect(!window.commands.supportsSplit)
    #expect(window.commands.toggleSplit == nil)
    #expect(window.commands.moveTabToOtherPane == nil)
    let actions = try #require(window.strip?.actions)
    #expect(actions.showInPane == nil)
    #expect(actions.reopenClosed == nil)
  }

  @Test("Strip actions on an id that names nothing change nothing")
  func actionsOnGhostTabs() throws {
    let session = try ServerSession.demo()
    let window = tabs(session)
    session.tabs.open(.chat(sessionID: "s"))
    let store = try #require(window.store)
    let before = store.tabs.map(\.id)
    let actions = try #require(window.strip?.actions)
    actions.select("ghost")
    actions.close("ghost")
    actions.setPinned("ghost", true)
    actions.duplicate("ghost")
    actions.closeOthers("ghost")
    actions.closeToRight("ghost")
    actions.move("ghost", .max)
    #expect(store.tabs.map(\.id) == before)
  }

  @Test("Replacing a tab that is gone opens a new one and shows its session")
  func showReplacingAGhost() throws {
    let session = try ServerSession.demo()
    let window = tabs(session)
    window.show(.chat(sessionID: "s"), in: "s", replacing: "ghost")
    #expect(session.tabs.currentSessionID == "s")
    #expect(session.tabs.group("s").tabs.contains { $0.content == .chat(sessionID: "s") })

    let page = session.tabs.group("s").open(.newTab)
    window.show(.harness(sessionID: "s"), in: "s", replacing: page.id)
    #expect(session.tabs.group("s").tab(page.id)?.content == .harness(sessionID: "s"))
  }

  @Test("Opening a browser does nothing in a build that has none")
  func noBrowser() throws {
    let session = try ServerSession.demo()
    let window = tabs(session)
    window.openBrowser(in: "s")
    #expect(session.tabs.currentSessionID == nil)
  }

  @Test("Control-` goes back to the chat from a terminal view")
  func toggleFromTerminal() throws {
    let session = try ServerSession.demo()
    let window = tabs(session)
    session.tabs.group("s").open(.harness(sessionID: "s"))
    session.tabs.show(.session("s"))
    window.toggleTerminal("s")
    #expect(session.tabs.group("s").selected?.content == .chat(sessionID: "s"))
  }

  @Test("Only chats and terminals have a terminal view")
  func terminalOffers() {
    #expect(WindowTabs.offersTerminal(.chat(sessionID: "")))
    #expect(WindowTabs.offersTerminal(.harness(sessionID: "")))
    #expect(WindowTabs.offersTerminal(.terminal(sessionID: "", terminalID: "")))
    #expect(!WindowTabs.offersTerminal(.newTab))
    #expect(!WindowTabs.offersTerminal(.sideChatSession(parentID: "", childID: nil)))
    let id = UUID()
    #expect(AppTabContent.browser(browserID: id).browserID == id)
    #expect(AppTabContent.newTab.browserID == nil)
  }

  @Test("The new-tab page offers only the shown session, and nothing without one")
  func newTabPage() async throws {
    let connection = try await ConversationFixtures.connection()
    connection.sessionList.apply(
      .reset(sessions: [
        ConversationFixtures.summary("s0", title: "Fix the build"),
        ConversationFixtures.summary("s1"),
      ]))
    let session = ServerSession(connection: connection)
    let window = tabs(session)
    #expect(window.newTabState == NewTabPageState())
    let sessionless = window.newTabActions(replacing: nil)
    #expect(sessionless.newTerminal == nil)
    #expect(sessionless.openRemoteBrowser == nil)

    session.tabs.group("s0").open(.newTab)
    session.tabs.show(.session("s0"))
    let state = window.newTabState
    #expect(state.sessionTitle == "Fix the build")
    #expect(state.terminals == .unknown)
    #expect(!state.canOpenBrowser)
    #expect(window.newTabActions(replacing: nil).newTerminal != nil)
  }

  @Test("New Tab's side chat replaces the page; a native agent's is typed in its chat")
  func newTabSideChat() async throws {
    let connection = try await ConversationFixtures.connection()
    connection.sessionList.apply(.reset(sessions: [ConversationFixtures.summary("s0")]))
    let session = ServerSession(connection: connection)
    final class Failures { var messages: [String] = [] }
    let failures = Failures()
    let window = WindowTabs(
      session: session, context: TabWindowContext(), showAll: {},
      fail: { failures.messages.append($0) })
    let group = session.tabs.group("s0")
    group.open(.chat(sessionID: "s0"))
    var page = group.open(.newTab)
    session.tabs.show(.session("s0"))
    #expect(window.newTabActions(replacing: page.id).newSideChat == nil, "no harness yet")

    let conversation = try #require(connection.conversation("s0"))
    func setHarness(_ harness: String, wrapper: String? = nil, revision: UInt64) {
      let header = ConversationFixtures.header(
        settings: ConversationFixtures.settings(harness: harness, wrapper: wrapper))
      conversation.apply(
        revision: revision, change: TranscriptChange(rows: [], header: header, sections: []))
    }
    setHarness("claude-sdk", revision: 1)
    let startSideChat = try #require(window.newTabActions(replacing: page.id).newSideChat)
    startSideChat()
    #expect(group.tab(page.id)?.content == .sideChatSession(parentID: "s0", childID: nil))

    setHarness("codex-native", wrapper: "codex-native-ui", revision: 2)
    page = group.open(.newTab)
    let startNativeSideChat = try #require(window.newTabActions(replacing: page.id).newSideChat)
    startNativeSideChat()
    #expect(group.tab(page.id) == nil)
    #expect(group.selected?.content == .chat(sessionID: "s0"))
    #expect(conversation.composer.text == "/side ")

    page = group.open(.newTab)
    let startAgain = try #require(window.newTabActions(replacing: page.id).newSideChat)
    startAgain()
    #expect(conversation.composer.text == "/side ", "a draft in progress stays")
    #expect(failures.messages.count == 1)
  }

  @Test("Remote browser profiles list the default first, once each")
  func remoteProfiles() async throws {
    let connection = try await ConversationFixtures.connection()
    let session = ServerSession(
      connection: connection, remoteBrowser: FixtureRemoteBrowser(latency: .milliseconds(1)))
    let window = tabs(session)
    await session.remoteBrowsers?.loadProfiles(sessionID: "a")
    session.tabs.show(.session("b"))
    #expect(window.newTabState.remoteBrowserProfiles.isEmpty, "b's machine isn't read yet")
    session.tabs.show(.session("a"))
    #expect(window.newTabState.remoteBrowserProfiles == ["default", "work"])
    await window.openRemoteBrowser(in: "a", profile: "exploded", replacing: "ghost")
    #expect(
      session.tabs.group("a").tabs.contains {
        if case .remoteBrowser = $0.content { true } else { false }
      })
  }

  @Test("A side question's fields come from its activity by id")
  func sideChatDetails() {
    let activity = OmnigentCoreFFI.Activity(
      kind: .error, title: "", summary: "", status: "",
      details: [
        OmnigentCoreFFI.DetailSection(id: "question", title: "", text: "first", isCode: false),
        OmnigentCoreFFI.DetailSection(id: "question", title: "", text: "second", isCode: false),
      ], isFailure: false, recovery: nil)
    #expect(SideChatTabContainer.detail("question", in: activity) == "first")
    #expect(SideChatTabContainer.detail("answer", in: activity) == nil)
  }
}
