import Foundation
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentUITestSupport

/// Two pins and two projects, with titles, update times and creation dates that each sort
/// differently.
@MainActor
private enum SortFixture {
  static let work = SessionProject(id: "work", name: "Work", sessionIds: ["w3", "w2", "w1"])
  static let home = SessionProject(id: "home", name: "Home", sessionIds: ["h2", "h1"])

  static func session(_ id: String, _ title: String, updated: Int64, pinned: Bool = false)
    -> SessionSummary
  {
    SessionSummary(id: id, title: title, updatedAt: updated, isPinned: pinned)
  }

  /// The list as the core orders it: pins in pin order, then most recent first.
  static var state: SidebarViewState {
    var state = SidebarViewState(
      list: SessionListViewState(sessions: [
        session("p1", "Zebra", updated: 10, pinned: true),
        session("p2", "apple", updated: 30, pinned: true),
        session("p3", "Mango", updated: 20, pinned: true),
        session("w3", "Charlie", updated: 9), session("w2", "alpha", updated: 8),
        session("h2", "Kiwi", updated: 7), session("w1", "Bravo", updated: 6),
        session("h1", "Fig", updated: 5),
      ]))
    state.projects = [work, home]
    state.rowInfo = [
      "p1": SessionRowInfo(createdAt: 300), "p2": SessionRowInfo(createdAt: 100),
      "p3": SessionRowInfo(createdAt: 200), "w1": SessionRowInfo(createdAt: 900),
      "w2": SessionRowInfo(createdAt: 100),
    ]
    return state
  }

  static func ids(_ group: SessionGroup, _ state: SidebarViewState) -> [String] {
    SidebarSections.rows(of: group, in: state).map(\.id)
  }
}

@Suite("Sidebar group sort: each group's order")
@MainActor
struct SidebarGroupSortTests {
  private let workGroup = SessionGroup.project("work")
  private let homeGroup = SessionGroup.project("home")

  @Test("Until a sort is chosen, Pinned keeps the pin order and a project lists recent first")
  func defaults() {
    var state = SortFixture.state
    #expect(state.sort(of: .pinned) == .custom)
    #expect(state.sort(of: workGroup) == .recent)
    #expect(SortFixture.ids(.pinned, state) == ["p1", "p2", "p3"])
    #expect(SortFixture.ids(workGroup, state) == ["w3", "w2", "w1"])
    #expect(SortFixture.ids(.project("gone"), state).isEmpty)

    // The list's Ordering by creation reaches Pinned, as before, and no project.
    state.display.sortBy = .created
    #expect(state.sort(of: .pinned) == .created)
    #expect(state.sort(of: workGroup) == .recent)
    #expect(SortFixture.ids(.pinned, state) == ["p1", "p3", "p2"])
    #expect(SortFixture.ids(workGroup, state) == ["w3", "w2", "w1"])

    state.groupSorts.chosen[SessionGroup.pinned.key] = .custom
    #expect(SortFixture.ids(.pinned, state) == ["p1", "p2", "p3"], "a chosen sort wins")
  }

  @Test("Recent activity, Name and Date created each order a group their own way")
  func eachSort() {
    var state = SortFixture.state
    let pinned: [SessionGroupSort: [String]] = [
      .recent: ["p2", "p3", "p1"], .name: ["p2", "p3", "p1"], .created: ["p1", "p3", "p2"],
    ]
    // A session without a creation date sorts by its last update.
    let work: [SessionGroupSort: [String]] = [
      .recent: ["w3", "w2", "w1"], .name: ["w2", "w1", "w3"], .created: ["w1", "w2", "w3"],
    ]
    for sort in [SessionGroupSort.recent, .name, .created] {
      state.groupSorts.chosen = [SessionGroup.pinned.key: sort, workGroup.key: sort]
      #expect(SortFixture.ids(.pinned, state) == pinned[sort], "\(sort)")
      #expect(SortFixture.ids(workGroup, state) == work[sort], "\(sort)")
      #expect(SortFixture.ids(homeGroup, state) == ["h2", "h1"], "\(sort) leaves Home alone")
    }
    #expect(Set(SessionGroupSort.allCases.map(\.title)).count == SessionGroupSort.allCases.count)
  }

  @Test("Equal names and dates keep the order the list gave")
  func tiesAreStable() {
    let sessions = ["b", "a", "c"].map { SessionSummary(id: $0, title: "Same", updatedAt: 5) }
    for sort in [SessionGroupSort.recent, .name, .created] {
      let ordered = sort.ordered(sessions, createdAt: { _ in 1 }, custom: [])
      #expect(ordered.map(\.id) == ["b", "a", "c"], "\(sort)")
    }
  }

  @Test("Custom shows the remembered order, new sessions first and gone ones nowhere")
  func customOrder() {
    var state = SortFixture.state
    state.groupSorts.chosen[workGroup.key] = .custom
    #expect(SortFixture.ids(workGroup, state) == ["w3", "w2", "w1"], "nothing remembered yet")

    state.groupSorts.customOrder[workGroup.key] = ["w1", "left", "w3"]
    #expect(SortFixture.ids(workGroup, state) == ["w2", "w1", "w3"])

    // Two sessions that joined since go first, most recent first.
    state.groupSorts.customOrder[workGroup.key] = ["w1"]
    #expect(SortFixture.ids(workGroup, state) == ["w3", "w2", "w1"])

    // Pinned's Custom is the server's pin order, whatever is remembered here.
    state.groupSorts.chosen[SessionGroup.pinned.key] = .custom
    state.groupSorts.customOrder[SessionGroup.pinned.key] = ["p3", "p2", "p1"]
    #expect(SortFixture.ids(.pinned, state) == ["p1", "p2", "p3"])
  }

  @Test("One group's sort leaves every other group as it was")
  func groupsAreIndependent() {
    var state = SortFixture.state
    state.groupSorts.chosen = [workGroup.key: .name, SessionGroup.pinned.key: .recent]
    state.groupSorts.customOrder[homeGroup.key] = ["h1", "h2"]
    #expect(SortFixture.ids(.pinned, state) == ["p2", "p3", "p1"])
    #expect(SortFixture.ids(workGroup, state) == ["w2", "w1", "w3"])
    #expect(SortFixture.ids(homeGroup, state) == ["h2", "h1"], "Home is not on Custom")
    state.groupSorts.chosen[homeGroup.key] = .custom
    #expect(SortFixture.ids(homeGroup, state) == ["h1", "h2"])
    #expect(SortFixture.ids(workGroup, state) == ["w2", "w1", "w3"])
  }

  @Test("The sections, the keyboard's order and the pinned shortcuts follow each group's sort")
  func navigationFollows() {
    var state = SortFixture.state
    state.groupSorts.chosen = [SessionGroup.pinned.key: .name, workGroup.key: .name]
    let pinned = SidebarSections.sections(state).first(where: \.isPinned)
    #expect(pinned?.sessions.map(\.id) == ["p2", "p3", "p1"])
    #expect(SidebarNavigationOrder.groupIDs(.pinned, in: state) == ["p2", "p3", "p1"])
    let order = SidebarNavigationOrder.sessionIDs(
      state, collapsed: [], expandedProjects: ["work"], shownInProject: ["work": 10])
    #expect(order == ["p2", "p3", "p1", "w2", "w1", "w3"])

    state.display.groupBy = .status
    let grouped = SidebarSections.sections(state).first(where: \.isPinned)
    #expect(grouped?.sessions.map(\.id) == ["p2", "p3", "p1"], "Pinned sorts under any grouping")
  }

  @Test("A project whose rows changed places is a new arrangement of the list")
  func arrangement() {
    let state = SortFixture.state
    var sorted = state
    sorted.groupSorts.chosen[workGroup.key] = .name
    #expect(SidebarArrangement(sorted) != SidebarArrangement(state))
    var same = state
    same.groupSorts.chosen[workGroup.key] = .recent
    #expect(SidebarArrangement(same) == SidebarArrangement(state))
  }

  @Test("Only a sort by what the rows say makes the list follow its rows")
  func followsRows() {
    #expect(!SessionGroupSorts().followsRows)
    #expect(SessionGroupSorts(chosen: [workGroup.key: .name]).followsRows)
    #expect(SessionGroupSorts(chosen: [SessionGroup.pinned.key: .recent]).followsRows)
    // A project's recent order is the list's own, which already reports its moves.
    #expect(!SessionGroupSorts(chosen: [workGroup.key: .recent]).followsRows)
    let stays = SessionGroupSorts(chosen: [workGroup.key: .custom, homeGroup.key: .created])
    #expect(!stays.followsRows)
  }

  @Test("The menu bar offers Pinned while something is pinned, then each project")
  func menuChoices() {
    var state = SortFixture.state
    state.groupSorts.chosen[homeGroup.key] = .name
    let choices = GroupSortChoice.choices(state)
    #expect(choices.map(\.id) == [.pinned, workGroup, homeGroup])
    #expect(choices.map(\.title) == ["Pinned", "Work", "Home"])
    #expect(choices.map(\.sort) == [.custom, .recent, .name])
    state.list.sessions.removeAll(where: \.isPinned)
    #expect(GroupSortChoice.choices(state).map(\.id) == [workGroup, homeGroup])
  }
}

@Suite("Sidebar group sort: choosing, reordering and forgetting")
@MainActor
struct SidebarGroupSortEditTests {
  private let work = SessionGroup.project("work")

  @Test("A project's first Custom keeps the rows where they are; later ones keep what it has")
  func choosing() {
    var sorts = SessionGroupSorts()
    sorts.choose(.name, for: work, shown: ["a", "b"])
    #expect(sorts.chosen == [work.key: .name])
    #expect(sorts.customOrder.isEmpty)

    sorts.choose(.custom, for: work, shown: [])
    #expect(sorts.customOrder.isEmpty, "nothing on screen to keep")
    sorts.choose(.custom, for: work, shown: ["b", "a"])
    #expect(sorts.customOrder == [work.key: ["b", "a"]])
    sorts.choose(.recent, for: work, shown: ["a", "b"])
    sorts.choose(.custom, for: work, shown: ["a", "b"])
    #expect(sorts.customOrder == [work.key: ["b", "a"]], "the remembered order comes back")

    sorts.choose(.custom, for: .pinned, shown: ["p1", "p2"])
    #expect(sorts.chosen[SessionGroup.pinned.key] == .custom)
    #expect(sorts.customOrder[SessionGroup.pinned.key] == nil, "the server keeps the pin order")
  }

  @Test("A reorder switches the group to Custom with the order on screen")
  func reordering() {
    var sorts = SessionGroupSorts(chosen: [work.key: .name])
    sorts.reorder(work, shown: ["b", "c", "a"])
    #expect(sorts.chosen[work.key] == .custom)
    #expect(sorts.customOrder[work.key] == ["b", "c", "a"])

    sorts.reorder(.pinned, shown: ["p2", "p1"])
    #expect(sorts.chosen[SessionGroup.pinned.key] == .custom)
    #expect(sorts.customOrder[SessionGroup.pinned.key] == nil)
    #expect(sorts.customOrder[work.key] == ["b", "c", "a"], "the project keeps its own")
  }

  @Test("Remembered sessions that are not on screen stay after the row they followed")
  func mergingHiddenRows() {
    let merged = { SessionGroupSorts.merged(stored: $0, shown: $1) }
    #expect(merged([], ["a", "b"]) == ["a", "b"])
    // A search shows a and c only; b and d keep following them.
    #expect(merged(["a", "b", "c", "d"], ["c", "a"]) == ["c", "d", "a", "b"])
    // A session new to the group lands where it was dropped.
    #expect(merged(["a", "b"], ["a", "new", "b"]) == ["a", "new", "b"])
    // One hidden above every row on screen stays first.
    #expect(merged(["hidden", "a", "b"], ["b", "a"]) == ["hidden", "b", "a"])
  }

  @Test("Sessions that left a fully known project are forgotten, and so are deleted projects")
  func pruning() {
    let home = SessionGroup.project("home")
    let saved = SessionGroupSorts(
      chosen: [work.key: .custom, home.key: .name, SessionGroup.pinned.key: .recent],
      customOrder: [work.key: ["a", "left", "b"], home.key: ["x"]])

    var sorts = saved
    sorts.keep(members: ["work": ["a", "b", "new"]])
    #expect(sorts.customOrder[work.key] == ["a", "b"])
    #expect(sorts.chosen == saved.chosen)
    #expect(sorts.customOrder[home.key] == ["x"], "Home's sessions are not all known")

    sorts = saved
    sorts.keep(projects: ["work"])
    #expect(sorts.chosen == [work.key: .custom, SessionGroup.pinned.key: .recent])
    #expect(sorts.customOrder == [work.key: ["a", "left", "b"]])

    sorts = saved
    sorts.keep(members: ["work": [], "other": ["a"]])
    #expect(sorts.customOrder[work.key] == nil, "an emptied order takes no room")
    #expect(sorts.chosen[work.key] == .custom)
    #expect(sorts.customOrder[home.key] == ["x"])
  }

  private func state(_ edit: (inout SidebarViewState) -> Void = { _ in }) -> SidebarViewState {
    var state = SidebarViewState(
      list: SessionListViewState(sessions: [SessionSummary(id: "a", title: "A")]))
    state.projects = [SessionProject(id: "work", name: "Work", sessionIds: ["a"])]
    state.projectSort = .manual
    state.paging.loadedProjects = ["work"]
    edit(&state)
    return state
  }

  @Test("The sidebar's state says what is gone only while it shows every session of a project")
  func pruningFromTheSidebar() {
    let saved = SessionGroupSorts(
      chosen: [work.key: .custom, SessionGroup.project("deleted").key: .name],
      customOrder: [work.key: ["left", "a"]])
    var sorts = saved
    sorts.prune(to: state(), isSearching: false)
    #expect(sorts == SessionGroupSorts(chosen: [work.key: .custom], customOrder: [work.key: ["a"]]))

    let keepsSessions: [(String, (inout SidebarViewState) -> Void)] = [
      ("a quick filter", { $0.quickFilter = .running }),
      ("the archived list", { $0.display.show = .archived }),
      ("a folder not read yet", { $0.paging.loadedProjects = [] }),
      ("a folder with more pages", { $0.paging.projectsWithMore = ["work"] }),
    ]
    for (reason, edit) in keepsSessions {
      sorts = saved
      sorts.prune(to: state(edit), isSearching: false)
      #expect(sorts.customOrder == saved.customOrder, "\(reason)")
      #expect(sorts.chosen == [work.key: .custom], "\(reason)")
    }
    sorts = saved
    sorts.prune(to: state(), isSearching: true)
    #expect(sorts.customOrder == saved.customOrder, "a search hides sessions")

    // Until the projects are read none is known to be gone; other groupings list none at all.
    sorts = saved
    sorts.prune(to: state { $0.projectSort = nil }, isSearching: false)
    #expect(sorts.chosen == saved.chosen)
    #expect(sorts.customOrder == [work.key: ["a"]])
    sorts = saved
    sorts.prune(to: state { $0.display.groupBy = .status }, isSearching: false)
    #expect(sorts == saved)
  }

  @Test("The sorts survive a save and a read")
  func codableRoundTrip() throws {
    let sorts = SessionGroupSorts(
      chosen: [work.key: .custom, SessionGroup.pinned.key: .name],
      customOrder: [work.key: ["b", "a"]])
    let data = try JSONEncoder().encode(sorts)
    #expect(try JSONDecoder().decode(SessionGroupSorts.self, from: data) == sorts)
  }

  @Test("Moving one of a group's rows gives the new order, or nothing when it stays put")
  func movingRows() {
    let rows = ["a", "b", "c"].map { SessionSummary(id: $0, title: $0) }
    #expect(rows.moved("c", .upOne).map(\.id) == ["a", "c", "b"])
    #expect(rows.moved("a", .bottom).map(\.id) == ["b", "c", "a"])
    #expect(rows.moved("a", .upOne).isEmpty)
    #expect(rows.moved("gone", .top).isEmpty)
    #expect(rows.reordered(moving: "a", onto: "c").map(\.id) == ["b", "c", "a"])
    #expect(rows.reordered(moving: "a", onto: "gone").isEmpty)
  }
}
