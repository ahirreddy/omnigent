#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents
  @testable import OmnigentUITestSupport

  /// An Add nested agent composer's provisional row in the sidebar: the last of its source's
  /// family, highlighted while its composer is open, with Delete Draft its only action.
  @Suite("Add nested agent: the provisional row", .serialized)
  @MainActor
  struct NestedAgentDraftRowTests {
    private let family = SessionFamilyInfo(id: "src", representativeID: "src")

    private var state: SidebarViewState {
      var state = SidebarViewState(
        list: SessionListViewState(sessions: [
          SessionSummary(id: "src", title: "Coordinator", family: family),
          SessionSummary(
            id: "draft", title: "New nested agent", canRename: false, canPin: false,
            canArchive: false, isNestedMember: true, family: family),
        ]))
      state.rowInfo["draft"] = SessionRowInfo(createdAt: 99)
      state.nestedDrafts = ["draft": "src"]
      return state
    }

    @Test("it stands for its composer, and any other row for its session")
    func destinations() {
      let state = state
      #expect(state.destination(of: state.list.sessions[1]) == .nestedSession(sourceID: "src"))
      #expect(state.destination(of: state.list.sessions[0]) == .session("src"))
      var actions = SessionListActions()
      actions.rename = { _, _ in }
      actions.deleteNestedDraft = { _ in }
      #expect(state.rowActions(state.list.sessions[1], actions).rename == nil)
      #expect(state.rowActions(state.list.sessions[0], actions).rename != nil)
      #expect(state.rowActions(state.list.sessions[1], actions).deleteNestedDraft != nil)
      #expect(state.rowActions(state.list.sessions[0], actions).deleteNestedDraft == nil)
    }

    @Test("it shows under its source, offers Delete Draft alone, and reopens the composer")
    func row() throws {
      let spy = SidebarSpy(state)
      var actions = spy.actions
      actions.sessions.addNestedAgent = { [spy] in spy.calls.append("nested \($0.id)") }
      actions.sessions.deleteNestedDraft = { [spy] in spy.calls.append("delete \($0.id)") }
      let screen = OffscreenWindow(
        SidebarHarness(spy: spy, actions: actions), width: 300, height: 700)
      defer { screen.close() }
      #expect(try screen.shows("New nested agent"))
      let list = try #require(screen.list)
      var menus: [(row: Int, menu: NSMenu)] = []
      for row in 0..<list.numberOfRows {
        if let menu = try screen.menu(ofRow: row), menu.item(named: "Copy Session ID") != nil {
          menus.append((row, menu))
        }
      }
      try #require(menus.count == 2, "the source and its provisional row")
      #expect(menus[0].menu.item(named: "Add nested agent") != nil, "the source offers it")
      #expect(menus[1].menu.item(named: "Add nested agent") == nil)
      #expect(menus[1].menu.item(named: "Rename\u{2026}") == nil)
      #expect(menus[1].menu.item(named: "Delete\u{2026}") == nil)
      #expect(menus[1].menu.item(named: "Delete Draft") != nil)
      #expect(menus[0].menu.item(named: "Delete Draft") == nil)
      try screen.clickRow(menus[1].row)
      #expect(spy.selection == .nestedSession(sourceID: "src"))
      #expect(spy.calls.isEmpty)
    }

    @Test("opening a composer opens its source's family, folder and section")
    func reveal() throws {
      let suite = "nested-reveal-\(UUID().uuidString)"
      let defaults = try #require(UserDefaults(suiteName: suite))
      defer { defaults.removePersistentDomain(forName: suite) }
      var state = state
      state.projects = [SessionProject(id: "p", name: "Alpha", sessionIds: ["src", "draft"])]
      let collapsedHere = SidebarFamilyScope.project("p").key(family: "src")
      let collapsedElsewhere = SidebarFamilyScope.section("Sessions").key(family: "other")
      state.collapsedFamilies = [collapsedHere, collapsedElsewhere]
      defaults.set("Projects\nPinned", forKey: SidebarNavigationOrder.collapsedSectionsKey)
      let left = SidebarNavigationOrder.reveal("src", in: state, defaults: defaults)
      #expect(left == [collapsedElsewhere])
      #expect(defaults.string(forKey: SidebarNavigationOrder.collapsedSectionsKey) == "Pinned")
      #expect(defaults.string(forKey: SidebarNavigationOrder.expandedProjectsKey) == "p")

      // A session on its own in Sessions opens that section.
      var loose = SidebarViewState(
        list: SessionListViewState(sessions: [SessionSummary(id: "solo", title: "Solo")]))
      loose.collapsedFamilies = [SidebarFamilyScope.section("Sessions").key(family: "solo")]
      defaults.set("Sessions", forKey: SidebarNavigationOrder.collapsedSectionsKey)
      #expect(SidebarNavigationOrder.reveal("solo", in: loose, defaults: defaults).isEmpty)
      #expect(defaults.string(forKey: SidebarNavigationOrder.collapsedSectionsKey)?.isEmpty == true)
      let unknown = SidebarNavigationOrder.reveal("unknown", in: loose, defaults: defaults)
      #expect(unknown == loose.collapsedFamilies, "nothing hides a session the sidebar lacks")
    }
  }
#endif
