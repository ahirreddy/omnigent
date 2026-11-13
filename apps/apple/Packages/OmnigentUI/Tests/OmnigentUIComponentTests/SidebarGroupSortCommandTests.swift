#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// What the menu bar reads from the window.
  @MainActor
  private final class PublishedSorts {
    var actions: SessionListCommandActions?
  }

  /// Reads the published session list commands as the app's menu bar does.
  private struct SortProbe: View {
    let published: PublishedSorts
    @FocusedValue(\.sessionListCommands) private var actions

    var body: some View {
      published.actions = actions
      return Color.clear.frame(width: 1, height: 1)
    }
  }

  @Suite("Sidebar group sort: the menu bar", .serialized)
  @MainActor
  struct SidebarGroupSortCommandTests {
    private func window(_ display: SessionListCommandActions) -> OffscreenWindow<AnyView> {
      OffscreenWindow(
        AnyView(
          Menu("Items") { SessionListMenuItems(display: display) }.frame(width: 200, height: 40)),
        width: 200, height: 40)
    }

    @Test("Session List sorts Pinned and each project, checking the sort each has")
    func sortsEachGroup() throws {
      var chosen: [String] = []
      var state = GroupSortFixture.state
      state.groupSorts.chosen[SessionGroup.project("home").key] = .name
      let screen = window(
        SessionListCommandActions(
          options: state.display, showsShared: true, groups: GroupSortChoice.choices(state),
          set: { _ in }, setGroupSort: { chosen.append("\($0.key) \($1)") }))
      defer { screen.close() }
      let list = try #require(try screen.openMenu(control: 0).item(named: "Session List")?.submenu)
      let pinned = try #require(list.item(named: "Sort Pinned Sessions By")?.submenu)
      #expect(pinned.item(named: SessionGroupSort.custom.title)?.state == .on)
      try screen.choose(SessionGroupSort.recent.title, in: pinned)
      let projects = try #require(list.item(named: "Sort Project Sessions By")?.submenu)
      #expect(projects.titles == ["Work", "Home"])
      let home = try #require(projects.item(named: "Home")?.submenu)
      #expect(home.item(named: SessionGroupSort.name.title)?.state == .on)
      try screen.choose(SessionGroupSort.custom.title, in: home)
      #expect(chosen == ["pinned recent", "project:home custom"])
    }

    @Test("With nothing pinned and no projects, or no way to sort, Session List offers no sort")
    func nothingToSort() throws {
      let options = SessionDisplayOptions()
      for actions in [
        SessionListCommandActions(
          options: options, showsShared: true, set: { _ in }, setGroupSort: { _, _ in }),
        SessionListCommandActions(
          options: options, showsShared: true,
          groups: GroupSortChoice.choices(GroupSortFixture.state), set: { _ in }),
      ] {
        let screen = window(actions)
        defer { screen.close() }
        let list = try #require(
          try screen.openMenu(control: 0).item(named: "Session List")?.submenu)
        #expect(list.item(named: "Sort Pinned Sessions By") == nil)
        #expect(list.item(named: "Sort Project Sessions By") == nil)
        #expect(list.item(named: "Ordering") != nil)
      }
    }

    @Test("The published sorts change with a group's sort, and a choice reaches the latest action")
    func relayForwards() throws {
      let relay = FocusedActionsRelay<SessionListCommandActions>()
      var chosen: [String] = []
      let state = GroupSortFixture.state
      let actions = { (state: SidebarViewState, name: String) in
        SessionListCommandActions(
          options: state.display, showsShared: true, groups: GroupSortChoice.choices(state),
          set: { _ in }, setGroupSort: { group, _ in chosen.append("\(name) \(group.key)") })
      }
      _ = relay.publish(actions(state, "first"))
      let published = try #require(relay.publish(actions(state, "second")))
      #expect(relay.publications == 1)
      published.setGroupSort?(.pinned, .name)
      #expect(chosen == ["second pinned"])

      var sorted = state
      sorted.groupSorts.chosen[SessionGroup.pinned.key] = .name
      _ = relay.publish(actions(sorted, "third"))
      #expect(relay.publications == 2, "the checkmark moves")
      let plain = SessionListCommandActions(options: state.display, showsShared: true) { _ in }
      #expect(plain.forwarding { plain }.setGroupSort == nil)
    }

    @Test("The window publishes its sidebar's groups, and a choice reaches the sidebar's action")
    func shellPublishes() async throws {
      let spy = SidebarSpy(GroupSortFixture.state)
      let published = PublishedSorts()
      var withoutSort = spy.actions
      withoutSort.setGroupSort = nil
      for (actions, groups) in [(spy.actions, 3), (withoutSort, 0)] {
        published.actions = nil
        let shell = ZStack {
          AppShell(
            sidebar: spy.state, selection: .constant(nil), searchText: .constant(""),
            actions: actions
          ) { _ in
            Color.clear
          }
          SortProbe(published: published)
        }
        let screen = OffscreenWindow(AnyView(shell), width: 900, height: 600)
        defer { screen.close() }
        let arrived = try await waitUntil(screen) { published.actions != nil }
        #expect(arrived)
        #expect(published.actions?.groups.count == groups)
        published.actions?.setGroupSort?(.project("work"), .name)
      }
      #expect(spy.calls.filter { $0.hasPrefix("sort") } == ["sort project:work name"])
    }
  }
#endif
