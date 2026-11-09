#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sidebar: what an empty list says", .serialized)
  @MainActor
  struct SessionListEmptyStateTests {
    private let project = SessionProject(id: "p", name: "Work", sessionIds: [])
    private typealias Content = SidebarEmptyState.Content

    private func state(
      sessions: [SessionSummary] = [], projects: [SessionProject] = [],
      filter: SessionFilter? = nil, show: SessionShowScope = SessionDisplayOptions().show,
      phase: SessionListPhase = .loaded
    ) -> SidebarViewState {
      var state = SidebarViewState(list: SessionListViewState(sessions: sessions, phase: phase))
      state.projects = projects
      state.quickFilter = filter
      state.display.show = show
      return state
    }

    @Test("a list with sessions never explains itself")
    func sessionsShowNothing() {
      let list = state(sessions: [SidebarFixture.beta], filter: .running)
      #expect(SidebarEmptyState.content(state: list, searchText: "x") == .nothing)
      #expect(SidebarEmptyState.content(state: list, searchText: "") == .nothing)
    }

    @Test("a quick filter says what it hid, unless a search is on")
    func quickFilters() {
      #expect(
        SidebarEmptyState.content(state: state(filter: .running), searchText: "")
          == .filteredOut("Nothing is running"))
      #expect(
        SidebarEmptyState.content(state: state(filter: .needsResponse), searchText: "")
          == .filteredOut("Nothing needs you"))
      #expect(
        SidebarEmptyState.content(state: state(filter: .running), searchText: "q")
          == .noMatches("q"))
      #expect(SidebarEmptyState.content(state: state(filter: .all), searchText: "") != .nothing)
    }

    @Test("project folders alone need no explanation")
    func foldersAlone() {
      #expect(
        SidebarEmptyState.content(state: state(projects: [project]), searchText: "") == .nothing)
    }

    @Test("a search or Archived that finds nothing says so even beside project folders")
    func searchBesideFolders() {
      #expect(
        SidebarEmptyState.content(state: state(projects: [project]), searchText: "zebra")
          == .noMatches("zebra"))
      #expect(
        SidebarEmptyState.content(
          state: state(projects: [project], show: .archived), searchText: "")
          == .empty("No archived sessions"))
    }

    @Test("an empty list reads as loading, then as empty")
    func phases() {
      #expect(SidebarEmptyState.content(state: state(phase: .loading), searchText: "") == .loading)
      #expect(SidebarEmptyState.content(state: state(), searchText: "") == .empty("No sessions"))
      #expect(
        SidebarEmptyState.content(state: state(phase: .failed(message: "x")), searchText: "")
          == .empty("No sessions"))
      #expect(
        SidebarEmptyState.content(state: state(show: .archived), searchText: "")
          == .empty("No archived sessions"))
    }

    @Test("every empty state draws without a list around it")
    func draws() throws {
      for (list, query) in [
        (state(), ""), (state(phase: .loading), ""), (state(), "q"), (state(show: .archived), ""),
        (state(sessions: [SidebarFixture.beta]), ""),
      ] {
        let screen = OffscreenWindow(
          SidebarEmptyState(state: list, searchText: query), width: 280, height: 120)
        screen.close()
      }
    }
  }
#endif
