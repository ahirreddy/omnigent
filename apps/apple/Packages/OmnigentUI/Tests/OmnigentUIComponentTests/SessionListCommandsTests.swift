#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the menu bar reads from the window.
  @MainActor
  private final class PublishedDisplay {
    var actions: SessionListCommandActions?
  }

  /// Reads the published display options as the app's menu bar does.
  private struct DisplayProbe: View {
    let published: PublishedDisplay
    @FocusedValue(\.sessionListCommands) private var actions

    var body: some View {
      published.actions = actions
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  /// A sidebar section header is one accessibility element, so the display menu in it is out of
  /// reach of the keyboard and of assistive clients. The menu bar offers the same choices.
  @Suite("Commands: the session list's display options in the View menu", .serialized)
  @MainActor
  struct SessionListCommandsTests {
    private func window(_ display: SessionListCommandActions?) -> OffscreenWindow<AnyView> {
      OffscreenWindow(
        AnyView(
          Menu("Items") { SessionListMenuItems(display: display) }.frame(width: 200, height: 40)),
        width: 200, height: 40)
    }

    @Test("Session List holds the sidebar's display menu, and a choice writes its option")
    func choosesAScope() throws {
      var written: [SessionDisplayOptions] = []
      let options = SessionDisplayOptions()
      let screen = window(
        SessionListCommandActions(options: options, showsShared: false) { written.append($0) })
      defer { screen.close() }
      let list = try #require(try screen.openMenu(control: 0).item(named: "Session List"))
      #expect(list.isEnabled)
      let menu = try #require(list.submenu)
      #expect(menu.item(named: "Grouping") != nil)
      #expect(menu.item(named: "Ordering") != nil)
      #expect(menu.item(named: "Show") != nil)
      try screen.choose(SessionShowScope.archived.title, in: menu)
      #expect(written.last?.show == .archived)
      #expect(written.last?.groupBy == options.groupBy)
    }

    @Test("Session List is disabled in a window with no session list")
    func disabledWithoutAList() throws {
      let screen = window(nil)
      defer { screen.close() }
      let list = try #require(try screen.openMenu(control: 0).item(named: "Session List"))
      #expect(!list.isEnabled)
    }

    @Test("One value stays published while the options are the same, and writes with the latest")
    func keepsItsIdentity() throws {
      let relay = FocusedActionsRelay<SessionListCommandActions>()
      var written: [String] = []
      let options = SessionDisplayOptions()
      _ = relay.publish(
        SessionListCommandActions(options: options, showsShared: true) { _ in
          written.append("first")
        })
      let published = try #require(
        relay.publish(
          SessionListCommandActions(options: options, showsShared: true) { _ in
            written.append("second")
          }))
      #expect(relay.publications == 1)
      published.set(options)
      #expect(written == ["second"])

      let archived = try #require(
        relay.publish(
          SessionListCommandActions(
            options: SessionDisplayOptions(show: .archived), showsShared: true
          ) { _ in }))
      #expect(relay.publications == 2, "the menu's checkmark moves")
      #expect(archived.options.show == .archived)
    }

    private func shell(_ actions: SidebarActions, _ published: PublishedDisplay) -> some View {
      ZStack {
        AppShell(
          sidebar: SidebarFixture.state, selection: .constant(nil), searchText: .constant(""),
          actions: actions
        ) { _ in
          Color.clear
        }
        DisplayProbe(published: published)
      }
    }

    @Test("The window publishes its sidebar's options, and a write reaches the sidebar's action")
    func shellPublishes() async throws {
      var written: [SessionDisplayOptions] = []
      let published = PublishedDisplay()
      let actions = SidebarActions(
        sessions: SessionListActions(), setDisplay: { written.append($0) })
      let screen = OffscreenWindow(AnyView(shell(actions, published)), width: 900, height: 600)
      defer { screen.close() }
      let arrived = await screen.waitUntil { published.actions != nil }
      #expect(arrived)
      let display = try #require(published.actions)
      #expect(display.options == SidebarFixture.state.display)
      #expect(display.showsShared == SidebarFixture.state.showsSharedScope)
      display.set(display.options)
      #expect(written == [display.options])
    }

    @Test("A sidebar that cannot change its display publishes nothing")
    func nothingWithoutAnAction() async throws {
      let published = PublishedDisplay()
      let actions = SidebarActions(sessions: SessionListActions())
      let screen = OffscreenWindow(AnyView(shell(actions, published)), width: 900, height: 600)
      defer { screen.close() }
      try await letTasksRun(screen)
      #expect(published.actions == nil)
    }
  }
#endif
