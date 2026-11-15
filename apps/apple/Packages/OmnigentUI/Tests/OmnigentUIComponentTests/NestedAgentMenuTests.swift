#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Add nested agent in a session row's menus: first, with a separator after it, and only for
  /// the viewer's own session that is not archived, on a server that can add one.
  @Suite("Add nested agent: row menus", .serialized)
  @MainActor
  struct NestedAgentRowMenuTests {
    private func sidebar(_ state: SidebarViewState, offered: Bool = true) -> (
      SidebarSpy, OffscreenWindow<SidebarHarness>
    ) {
      let spy = SidebarSpy(state)
      var actions = spy.actions
      if offered {
        actions.sessions.addNestedAgent = { [spy] in spy.calls.append("nested \($0.id)") }
      }
      return (
        spy, OffscreenWindow(SidebarHarness(spy: spy, actions: actions), width: 300, height: 700)
      )
    }

    /// The menu of the sidebar's one session row.
    private func sessionMenu(_ screen: OffscreenWindow<SidebarHarness>) throws -> NSMenu {
      let list = try #require(screen.list)
      for row in 0..<list.numberOfRows {
        if let menu = try screen.menu(ofRow: row), menu.item(named: "Copy Session ID") != nil {
          return menu
        }
      }
      throw OffscreenWindowError.notFound("a session row's menu")
    }

    private func state(_ session: SessionSummary) -> SidebarViewState {
      SidebarViewState(list: SessionListViewState(sessions: [session]))
    }

    @Test("an owned session's right-click menu leads with it, and choosing it reaches the host")
    func leadsTheContextMenu() throws {
      let (spy, screen) = sidebar(state(SessionSummary(id: "own", title: "Mine")))
      defer { screen.close() }
      let menu = try sessionMenu(screen)
      #expect(menu.items.first?.title == "Add nested agent")
      #expect(menu.items.dropFirst().first?.isSeparatorItem == true)
      try screen.choose("Add nested agent", in: menu)
      #expect(spy.calls == ["nested own"])
    }

    @Test("a shared, an archived or an unsupported session's menu leaves it out")
    func gated() throws {
      var shared = state(SessionSummary(id: "theirs", title: "Theirs"))
      shared.rowInfo["theirs"] = SessionRowInfo(isShared: true)
      var archived = state(SessionSummary(id: "old", title: "Old", isArchived: true))
      archived.display.show = .archived
      for (rowState, offered) in [
        (shared, true), (archived, true), (state(SessionSummary(id: "s", title: "S")), false),
      ] {
        let (_, screen) = sidebar(rowState, offered: offered)
        defer { screen.close() }
        let menu = try sessionMenu(screen)
        #expect(menu.item(named: "Add nested agent") == nil)
        #expect(menu.items.first?.isSeparatorItem == false, "no stray separator leads it")
      }
    }

    @Test("the hover More menu leads with it too")
    func leadsTheHoverMenu() throws {
      let spy = SidebarSpy(SidebarFixture.state)
      var actions = spy.sessionActions
      actions.addNestedAgent = { [spy] in spy.calls.append("nested \($0.id)") }
      let session = SessionSummary(id: "s", title: "Fix the build")
      let row = SessionRow(
        session: session, info: SessionRowInfo(), isUnread: false, attention: 0,
        details: [.updated], now: Date(timeIntervalSince1970: 3_600),
        menu: SessionRowMenu(
          session: session, isUnread: false, isShared: false, pinLimitReached: false,
          projects: [], actions: actions, rename: {}, confirmDelete: {}, confirmLeave: {},
          confirmStop: {}),
        isSelecting: false, isChecked: false
      )
      let screen = OffscreenWindow(row.frame(width: 280, height: 32), width: 280, height: 32)
      defer { screen.close() }
      try screen.hover(CGPoint(x: 140, y: 16))
      let menu = try screen.openMenu(try #require(screen.popUps.first))
      #expect(menu.titles.first == "Add nested agent")
      try screen.choose("Add nested agent", in: menu)
      #expect(spy.calls == ["nested s"])
    }
  }

  /// Holds what a conversation hands its toolbar, as the app's tab host receives it.
  @MainActor
  private final class NestedToolbarBox {
    var items: ConversationToolbarItems?
  }

  /// The Conversation menu as the menu bar builds it over what the window's conversation
  /// publishes, so its key reaches the screen as it does in the app.
  private struct NestedMenuBarStandIn: View {
    @FocusedValue(\.sessionCommands) private var commands

    var body: some View {
      Menu("Menu bar") { ConversationMenuItems(actions: commands) }
        .frame(width: 140, height: 28)
    }
  }

  /// A conversation with the session's header menu and a stand-in menu bar over it.
  private struct NestedConversationHost: View {
    let state: ConversationViewState
    let extras: ConversationExtras
    let box: NestedToolbarBox
    @State private var mode = SessionViewMode.chat
    @State private var showsInspector = false
    @State private var draft = ""

    var body: some View {
      VStack(spacing: 0) {
        NestedMenuBarStandIn()
        ConversationScreen(
          state: state, composer: ComposerViewState(), draft: ComposerDraft($draft),
          showsInspector: $showsInspector, mode: $mode, actions: ConversationActions(),
          composerActions: ComposerActions(send: {}), extras: extras
        ) {
          Text("terminal")
        }
        .hostsConversationToolbar()
        .backgroundPreferenceValue(ConversationToolbarKey.self) { items in
          box.items = items
          return Color.clear
        }
      }
    }
  }

  /// Add nested agent in the session header's menu and on Option-Command-A, for the viewer's own
  /// top-level session that is not archived.
  @Suite("Add nested agent: header menu and shortcut", .serialized)
  @MainActor
  struct NestedAgentHeaderTests {
    private let log = HostLog()
    private let box = NestedToolbarBox()

    init() {
      SystemSideEffects.reset()
    }

    private func screen(
      archived: Bool = false, shared: Bool = false, parent: String? = nil
    ) async throws -> OffscreenWindow<AnyView> {
      var state = ConversationViewState(
        header: TranscriptFixture.header, rows: [TranscriptFixture.answer("a")])
      state.summary = SessionSummary(id: "session-1", title: "A session", isArchived: archived)
      if let parent { state.header.settings = SessionSettings(parentId: parent) }
      var actions = SessionListActions()
      let log = log
      actions.addNestedAgent = { log.add("nested \($0.id)") }
      let window = transcriptScreen(
        NestedConversationHost(
          state: state,
          extras: ConversationExtras(
            sessionActions: actions, menuContext: SessionMenuContext(isShared: shared)),
          box: box),
        width: 900, height: 640)
      try await letTasksRun(window, milliseconds: 200)
      return window
    }

    /// The stand-in menu bar's Add Nested Agent item.
    private func menuItem(_ window: OffscreenWindow<AnyView>) throws -> NSMenuItem {
      let menu = try window.menu(at: 0)
      return try #require(menu.items.first { $0.title == "Add Nested Agent" })
    }

    /// Presses Option-Command-A as the menu bar matches it, before any view sees the key.
    private func pressShortcut(_ window: OffscreenWindow<AnyView>) async throws -> Bool {
      let menu = try window.menu(at: 0)
      let event = try #require(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [.command, .option],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.window.windowNumber, context: nil, characters: "a",
          charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
      let handled = menu.performKeyEquivalent(with: event)
      try await letTasksRun(window)
      return handled
    }

    @Test("the header menu leads with it and opens the composer beside the session")
    func headerMenu() async throws {
      let window = try await screen()
      defer { window.close() }
      let items = try #require(box.items)
      let menu = transcriptScreen(VStack { items.titleMenu }, height: 600)
      defer { menu.close() }
      #expect(try menu.shows("Add nested agent"))
      try menu.clickControl(at: 0)
      #expect(log.entries == ["nested session-1"])
    }

    @Test("the header menu leaves it out for a shared or archived session")
    func headerMenuGated() async throws {
      for (archived, shared) in [(true, false), (false, true)] {
        let window = try await screen(archived: archived, shared: shared)
        defer { window.close() }
        let items = try #require(box.items)
        let menu = transcriptScreen(VStack { items.titleMenu }, height: 600)
        defer { menu.close() }
        #expect(try !menu.shows("Add nested agent"))
      }
    }

    @Test("Option-Command-A opens it for the viewer's own session")
    func shortcut() async throws {
      let window = try await screen()
      defer { window.close() }
      let item = try menuItem(window)
      #expect(item.keyEquivalent == "a")
      #expect(item.keyEquivalentModifierMask == [.command, .option])
      #expect(item.isEnabled)
      #expect(try await pressShortcut(window))
      #expect(log.entries == ["nested session-1"])
    }

    @Test("Option-Command-A does nothing on an archived, shared or sub-agent session")
    func shortcutGated() async throws {
      for (archived, shared, parent) in [
        (true, false, String?.none), (false, true, nil), (false, false, "parent"),
      ] {
        let window = try await screen(archived: archived, shared: shared, parent: parent)
        defer { window.close() }
        #expect(try menuItem(window).isEnabled == false)
        _ = try await pressShortcut(window)
        #expect(log.entries.isEmpty)
      }
    }
  }
#endif
