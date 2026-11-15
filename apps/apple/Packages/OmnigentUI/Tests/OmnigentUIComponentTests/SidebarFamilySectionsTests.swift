import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar families: sections, groups and order")
@MainActor
struct SidebarFamilySectionsTests {
  private let ids = FamilyFixture.ids
  private let work = SessionProject(
    id: "work", name: "Work", sessionIds: ["impl", "solo", "coord", "review"])

  @Test("A pinned family shows whole in Pinned, nested, and leaves its folder and the list")
  func pinnedFamily() {
    var state = FamilyFixture.pinnedState
    state.projects = [SessionProject(id: "work", name: "Work", sessionIds: ["impl", "review"])]
    let sections = SidebarSections.sections(state)
    #expect(sections.first?.isPinned == true)
    #expect(ids(sections.first?.sessions ?? []) == ["coord", "impl", "review"])
    #expect(SidebarSections.sessions(of: state.projects[0], in: state).isEmpty)
    #expect(ids(sections.last?.sessions ?? []) == ["solo"])
  }

  @Test("A legacy pin on a member leaves it nested in its family, listed once")
  func legacyMemberPin() {
    let memberPin = FamilyFixture.member("impl", "Implementation", updatedAt: 900, isPinned: true)
    let state = FamilyFixture.state([
      FamilyFixture.coordinator, memberPin, FamilyFixture.solo, FamilyFixture.review,
    ])
    let sections = SidebarSections.sections(state)
    let hasPinned = sections.contains { $0.isPinned }
    #expect(!hasPinned)
    #expect(ids(sections.last?.sessions ?? []) == ["coord", "impl", "review", "solo"])
  }

  @Test("Without its representative loaded the oldest member heads, where its family stands")
  func representativeNotLoaded() {
    let state = FamilyFixture.state([
      FamilyFixture.review, FamilyFixture.solo, FamilyFixture.implementation,
    ])
    #expect(
      ids(SidebarSections.sections(state).last?.sessions ?? []) == ["impl", "review", "solo"])
  }

  @Test("Shared sessions stay flat and folders keep each family together")
  func foldersAndShared() {
    var state = FamilyFixture.state()
    state.projects = [work]
    state.rowInfo["other", default: SessionRowInfo()].isShared = true
    state.list.sessions.append(SessionSummary(id: "other", title: "Theirs", updatedAt: 1))
    let sections = SidebarSections.sections(state)
    #expect(
      ids(SidebarSections.sessions(of: work, in: state)) == ["coord", "impl", "review", "solo"])
    #expect(ids(sections.first { $0.title == "Shared" }?.sessions ?? []) == ["other"])
  }

  @Test("A folder's page counts every member, its head first; the family runs onto the next page")
  func familyAcrossAPage() {
    let loose = (1...4).map { SessionSummary(id: "s\($0)", title: "S\($0)", updatedAt: 2000 - $0) }
    var state = FamilyFixture.state(
      loose + [FamilyFixture.coordinator, FamilyFixture.implementation, FamilyFixture.review])
    state.projects = [
      SessionProject(
        id: "work", name: "Work", sessionIds: ["s1", "s2", "s3", "s4", "coord", "impl", "review"])
    ]
    let open = SidebarNavigationOrder.sessionIDs(state, collapsed: [], expandedProjects: ["work"])
    #expect(open == ["s1", "s2", "s3", "s4", "coord"])
    let more = SidebarNavigationOrder.sessionIDs(
      state, collapsed: [], expandedProjects: ["work"], shownInProject: ["work": 10])
    #expect(more == ["s1", "s2", "s3", "s4", "coord", "impl", "review"])
  }

  @Test("Keyboard order and Shift ranges skip a collapsed family's members")
  func navigationSkipsCollapsedMembers() {
    var state = FamilyFixture.state()
    #expect(
      SidebarNavigationOrder.sessionIDs(state, collapsed: [], expandedProjects: []) == [
        "coord", "impl", "review", "solo",
      ])
    state.collapsedFamilies = [SidebarFamilyScope.section("Sessions").key(family: "coord")]
    #expect(
      SidebarNavigationOrder.sessionIDs(state, collapsed: [], expandedProjects: []) == [
        "coord", "solo",
      ])
    var pinned = FamilyFixture.pinnedState
    pinned.collapsedFamilies = [SidebarFamilyScope.section("Pinned").key(family: "coord")]
    let defaults = UserDefaults(suiteName: "families-\(UUID().uuidString)") ?? .standard
    #expect(SidebarNavigationOrder.pinnedIDs(pinned, defaults: defaults) == ["coord"])
  }

  @Test("Status puts a family where its most urgent member goes, nested there")
  func statusKeepsAFamily() {
    let waiting = SessionSummary(
      id: "review", title: "Review", updatedAt: 300, attention: .needsYou,
      family: FamilyFixture.family)
    var state = FamilyFixture.state([
      FamilyFixture.implementation, FamilyFixture.solo, FamilyFixture.coordinator, waiting,
    ])
    state.display.groupBy = .status
    let sections = SidebarSections.sections(state)
    #expect(
      ids(sections.first { $0.title == "Needs attention" }?.sessions ?? []) == [
        "coord", "impl", "review",
      ])
    #expect(ids(sections.first { $0.title == "Done" }?.sessions ?? []) == ["solo"])
  }

  @Test("Created and Harness follow the family's head; Updated its first member")
  func otherGroupsKeepAFamily() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let day: Int64 = 86_400
    let now = 40 * day + day / 2
    var state = FamilyFixture.state([
      FamilyFixture.member("impl", "Implementation", updatedAt: now - 60),
      FamilyFixture.member("coord", "Coordinator", updatedAt: now - 20 * day),
    ])
    state.list.now = Date(timeIntervalSince1970: TimeInterval(now))
    state.rowInfo = [
      "coord": SessionRowInfo(harness: "claude-code", createdAt: now - 20 * day),
      "impl": SessionRowInfo(harness: "codex", createdAt: now - 60),
    ]
    let titles = { (grouping: SessionGrouping) -> [String: [String]] in
      state.display.groupBy = grouping
      let sections = SidebarSections.sections(state, calendar: calendar)
      return Dictionary(uniqueKeysWithValues: sections.map { ($0.title, ids($0.sessions)) })
    }
    #expect(titles(.created) == ["Created in the last 30 days": ["coord", "impl"]])
    #expect(titles(.updated) == ["Updated today": ["coord", "impl"]])
    let claude = HarnessAppearance(harness: "claude-code").label
    #expect(titles(.harness) == [claude: ["coord", "impl"]])
  }

  @Test("A project orders its families as one, by family id in its custom order")
  func customOrderByFamily() {
    let family = SessionFamilyInfo(id: "origin", representativeID: "coord")
    var state = FamilyFixture.state([
      FamilyFixture.member("impl", "Implementation", updatedAt: 900, family: family),
      FamilyFixture.solo,
      FamilyFixture.member("coord", "Coordinator", updatedAt: 500, family: family),
    ])
    state.projects = [work]
    #expect(SidebarNavigationOrder.groupIDs(.project("work"), in: state) == ["origin", "solo"])
    let key = SessionGroup.project("work").key
    state.groupSorts = SessionGroupSorts(
      chosen: [key: .custom], customOrder: [key: ["solo", "origin"]])
    #expect(ids(SidebarSections.sessions(of: work, in: state)) == ["solo", "coord", "impl"])
    // Pinned's order is by pin, and a nested head's pin is its representative's.
    let nestedHead = FamilyFixture.implementation
    #expect(SidebarSections.orderIDs([nestedHead, FamilyFixture.solo], in: .pinned) == ["solo"])
  }

  @Test("Pruning keeps a family's saved place in its folder")
  func pruneKeepsAFamily() {
    let family = SessionFamilyInfo(id: "origin", representativeID: "coord")
    var state = FamilyFixture.state([
      FamilyFixture.member("coord", "Coordinator", updatedAt: 500, family: family),
      FamilyFixture.solo,
    ])
    state.projects = [SessionProject(id: "work", name: "Work", sessionIds: ["coord", "solo"])]
    state.paging = SidebarPaging(loadedProjects: ["work"])
    let key = SessionGroup.project("work").key
    var sorts = SessionGroupSorts(customOrder: [key: ["origin", "solo", "gone"]])
    sorts.prune(to: state, isSearching: false)
    #expect(sorts.customOrder[key] == ["origin", "solo"])
  }

  @Test("A nested member's drop does nothing; its representative's moves and orders the family")
  func drops() {
    var state = FamilyFixture.pinnedState
    let home = SessionProject(id: "home", name: "Home", sessionIds: [])
    state.projects = [home]
    state.list.sessions.append(SessionSummary(id: "lone", title: "Lone", isPinned: true))
    let log = FamilyCallLog()
    var actions = SidebarActions(sessions: SessionListActions())
    actions.dropSession = { log.calls.append("drop \($0.id) \($1)") }
    actions.reorderGroup = { log.calls.append("order \($0.key) \($1.joined(separator: ","))") }
    let handler = SidebarDropHandler(state: state, actions: actions)
    #expect(!handler.drop(.session("impl"), on: .project(home)))
    #expect(!handler.drop(.session("impl"), on: .sessions))
    #expect(handler.drop(.session("lone"), on: .pinSlot("coord")))
    #expect(handler.drop(.session("coord"), on: .project(home)))
    #expect(
      log.calls == [
        "order pinned lone,coord",
        "drop coord \(SidebarDropAction.move(to: home, unpin: true))",
      ])
    #expect(handler.move(in: .pinned)?.rows().map(\.id) == ["coord", "lone"])
    let pins = SidebarSections.Section(title: "Pinned", sessions: [], isPinned: true)
    #expect(handler.rowTarget(FamilyFixture.implementation, in: pins, isNested: true) == .pinned)
    #expect(handler.rowTarget(FamilyFixture.coordinator, in: pins) == .pinSlot("coord"))
  }
}

extension SidebarFamilySectionsTests {
  private func kind(_ family: SessionRowFamily) -> String {
    switch family {
    case .standalone: "standalone"
    case .nested: "nested"
    case .head(let isExpanded, _): isExpanded ? "expanded head" : "collapsed head"
    }
  }

  @Test("A head leads with a chevron only with members here and a host to collapse it")
  func layoutChoosesEachRowsPlace() {
    var state = FamilyFixture.state()
    let rows = SidebarSections.sections(state).last?.sessions ?? []
    let scope = SidebarFamilyScope.section("Sessions")
    let log = FamilyCallLog()
    let layout = SidebarFamilyLayout(rows: rows, scope: scope, state: state) { key, collapsed in
      log.calls.append("\(collapsed) \(key)")
    }
    #expect(
      rows.map { kind(layout.family(of: $0)) } == [
        "expanded head", "nested", "nested", "standalone",
      ])
    if case .head(_, let toggle) = layout.family(of: rows[0]) { toggle() }
    #expect(log.calls == ["true \(scope.key(family: "coord"))"])
    state.collapsedFamilies = [scope.key(family: "coord")]
    let collapsed = SidebarFamilyLayout(rows: rows, scope: scope, state: state) { _, _ in }
    #expect(ids(collapsed.visible) == ["coord", "solo"])
    #expect(kind(collapsed.family(of: rows[0])) == "collapsed head")
    let alone = SidebarFamilyLayout(
      rows: [FamilyFixture.coordinator, FamilyFixture.solo], scope: scope, state: state
    ) { _, _ in }
    #expect(kind(alone.family(of: FamilyFixture.coordinator)) == "standalone")
    let unhosted = SidebarFamilyLayout(
      rows: rows, listedCount: 2, scope: scope, state: state, setCollapsed: nil)
    #expect(kind(unhosted.family(of: rows[0])) == "standalone")
    #expect(ids(unhosted.visible) == ["coord"])
  }
}

/// What a test's host was asked to do.
@MainActor
final class FamilyCallLog {
  var calls: [String] = []
}
