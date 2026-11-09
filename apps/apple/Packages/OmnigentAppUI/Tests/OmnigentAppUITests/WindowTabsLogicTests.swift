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

  @Test("The new-tab page lists the shown session first and at most twelve")
  func newTabPage() async throws {
    let connection = try await ConversationFixtures.connection()
    let sessions = (0..<20).map { index in
      ConversationFixtures.summary("s\(index)", updatedAt: index == 0 ? .min : Int64(index))
    }
    connection.sessionList.apply(.reset(sessions: sessions))
    let session = ServerSession(connection: connection)
    let window = tabs(session)
    let page = session.tabs.group("s0").open(.newTab)
    session.tabs.show(.session("s0"))
    let state = window.newTabState
    #expect(state.recentSessions.count == 12)
    #expect(state.recentSessions.first?.id == "s0")
    #expect(state.recentSessions.dropFirst().first?.id == "s19")
    #expect(!state.canOpenBrowser)

    window.newTabActions(replacing: page.id).openSession("s5")
    #expect(session.tabs.group("s0").tab(page.id) == nil)
    #expect(session.tabs.currentSessionID == "s5")
  }

  @Test("Remote browser profiles list the default first, once each")
  func remoteProfiles() async throws {
    let connection = try await ConversationFixtures.connection()
    let session = ServerSession(
      connection: connection, remoteBrowser: FixtureRemoteBrowser(latency: .milliseconds(1)))
    let window = tabs(session)
    await session.remoteBrowsers?.loadProfiles(sessionID: "a")
    await session.remoteBrowsers?.loadProfiles(sessionID: "b")
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
