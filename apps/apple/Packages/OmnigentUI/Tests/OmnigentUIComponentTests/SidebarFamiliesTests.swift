import Foundation
import Testing

@testable import OmnigentUIComponents

@Suite("Sidebar families: order, pins and moves")
struct SidebarFamiliesTests {
  private let createdAt: (SessionSummary) -> Int64 = { FamilyFixture.created[$0.id] ?? 0 }
  private let ids = FamilyFixture.ids

  @Test("A family's head is its loaded representative; the rest follow oldest first")
  func headIsTheRepresentative() {
    let groups = SidebarFamilies.groups(FamilyFixture.sessions, createdAt: createdAt)
    #expect(groups.keys.sorted() == [FamilyFixture.familyID])
    #expect(ids(groups[FamilyFixture.familyID] ?? []) == ["coord", "impl", "review"])
  }

  @Test("Without its representative loaded the oldest member heads; ties: the source, then id")
  func headWithoutTheRepresentative() {
    let family = SessionFamilyInfo(id: "src", representativeID: "gone")
    let members = ["zed", "src", "alpha", "late"].map {
      SessionSummary(id: $0, title: $0, family: family)
    }
    let created: [String: Int64] = ["zed": 10, "src": 10, "alpha": 10, "late": 5]
    let groups = SidebarFamilies.groups(members) { created[$0.id] ?? 0 }
    #expect(ids(groups["src"] ?? []) == ["late", "src", "alpha", "zed"])
  }

  @Test("A family stands where its best-ranked member does, head first")
  func familyTakesItsBestPlace() {
    #expect(
      ids(SidebarFamilies.ordered(FamilyFixture.sessions, createdAt: createdAt)) == [
        "coord", "impl", "review", "solo",
      ])
    let soloFirst = [
      FamilyFixture.solo, FamilyFixture.review, FamilyFixture.coordinator,
      FamilyFixture.implementation,
    ]
    #expect(
      ids(SidebarFamilies.ordered(soloFirst, createdAt: createdAt)) == [
        "solo", "coord", "impl", "review",
      ])
  }

  @Test("A collapsed family shows its head alone, within a page too")
  func collapsedFamilyShowsItsHead() {
    let rows = SidebarFamilies.ordered(FamilyFixture.sessions, createdAt: createdAt)
    #expect(
      ids(SidebarFamilies.visible(rows) { $0 == FamilyFixture.familyID }) == ["coord", "solo"])
    #expect(
      ids(SidebarFamilies.visible(rows) { _ in false }) == ["coord", "impl", "review", "solo"])
    #expect(ids(SidebarFamilies.visible(rows.prefix(2)) { _ in false }) == ["coord", "impl"])
  }

  @Test("A nested member shows pinned with its representative, never by a legacy pin of its own")
  func memberPinsFollowTheRepresentative() {
    #expect(
      SidebarFamilies.pinnedIDs(FamilyFixture.pinnedState.list.sessions) == [
        "coord", "impl", "review",
      ])
    let legacyMemberPin = [
      FamilyFixture.coordinator,
      FamilyFixture.member("impl", "Implementation", updatedAt: 900, isPinned: true),
      FamilyFixture.solo,
    ]
    #expect(SidebarFamilies.pinnedIDs(legacyMemberPin).isEmpty)
    let legacyRepresentativePin = [
      FamilyFixture.member("coord", "Coordinator", updatedAt: 500, isPinned: true),
      FamilyFixture.implementation,
    ]
    #expect(SidebarFamilies.pinnedIDs(legacyRepresentativePin) == ["coord", "impl"])
  }

  @Test("Without its representative loaded a member follows its family's pin")
  func memberPinWithoutTheRepresentative() {
    let pinnedFamily = SessionFamilyInfo(id: "coord", representativeID: "coord", isPinned: true)
    let members = [
      FamilyFixture.member("impl", "Implementation", updatedAt: 900, family: pinnedFamily),
      FamilyFixture.review,
    ]
    #expect(SidebarFamilies.pinnedIDs(members) == ["impl"])
  }

  @Test("Pins take one slot per family and one per other session")
  func pinSlots() {
    var state = FamilyFixture.pinnedState
    state.list.sessions.append(SessionSummary(id: "lone", title: "Lone", isPinned: true))
    #expect(state.pinnedCount == 2)
  }

  @Test("Grouped views keep a family in one group by their rule")
  func groupRules() {
    let groupOf: [String: String] = ["impl": "B", "coord": "C", "review": "A", "solo": "S"]
    let titles = { (rule: SidebarFamilies.GroupRule) in
      SidebarFamilies.groupTitles(
        FamilyFixture.sessions, rule: rule, createdAt: createdAt, title: { groupOf[$0.id] ?? "" })
    }
    #expect(titles(.head) == ["coord": "C", "impl": "C", "review": "C", "solo": "S"])
    #expect(titles(.first) == ["coord": "B", "impl": "B", "review": "B", "solo": "S"])
    #expect(
      titles(.earliest(order: ["A", "B", "C"])) == [
        "coord": "A", "impl": "A", "review": "A", "solo": "S",
      ])
  }

  @Test("A bulk move needs each nested member's representative and sends only representatives")
  func bulkMoveTargets() {
    #expect(!SidebarFamilies.canBulkMove([FamilyFixture.implementation, FamilyFixture.solo]))
    let whole = [FamilyFixture.coordinator, FamilyFixture.implementation, FamilyFixture.solo]
    #expect(SidebarFamilies.canBulkMove(whole))
    #expect(ids(SidebarFamilies.bulkMoveTargets(whole)) == ["coord", "solo"])
  }

  @Test("Only a member under another session is nested")
  func nesting() {
    #expect(FamilyFixture.implementation.nestedUnder == "coord")
    #expect(FamilyFixture.implementation.isNestedFamilyMember)
    #expect(!FamilyFixture.coordinator.isNestedFamilyMember)
    #expect(!FamilyFixture.solo.isNestedFamilyMember)
    let unclaimed = SessionSummary(id: "a", title: "A", family: SessionFamilyInfo(id: "a"))
    #expect(!unclaimed.isNestedFamilyMember)
  }

  @Test("A search row's breadcrumb names its project and the session it's nested under")
  func breadcrumbs() {
    let loaded = { (id: String) in id == "coord" ? "Loaded coordinator" : nil }
    let titled = PaletteBreadcrumb.nested(
      FamilyFixture.implementation, project: "Work", loadedTitle: loaded)
    #expect(titled == PaletteBreadcrumb(project: "Work", parent: "Coordinator"))
    let untitled = FamilyFixture.member(
      "impl", "Implementation", updatedAt: 1,
      family: SessionFamilyInfo(id: "coord", representativeID: "coord"))
    #expect(
      PaletteBreadcrumb.nested(untitled, project: nil, loadedTitle: loaded)?.parent
        == "Loaded coordinator")
    #expect(
      PaletteBreadcrumb.nested(untitled, project: nil, loadedTitle: { _ in nil })?.parent
        == "Session group")
    #expect(
      PaletteBreadcrumb.nested(FamilyFixture.coordinator, project: "Work", loadedTitle: loaded)
        == nil)
  }
}
