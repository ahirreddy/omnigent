import Foundation
import Testing

@testable import OmnigentUIComponents
@testable import OmnigentUITestSupport

#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
#endif

/// Moving a session into another nest, or out of its own, from its row's Move session menu (the
/// web's Move session → Nests).
@Suite("Sidebar: moving sessions between nests", .serialized)
@MainActor
struct SidebarNestMoveTests {
  private static let team = SessionFamilyInfo(
    id: "team", representativeID: "lead", representativeTitle: "Team lead")

  private static var lead: SessionSummary {
    FamilyFixture.member("lead", "Team lead", updatedAt: 400, family: team)
  }

  private static var helper: SessionSummary {
    FamilyFixture.member("helper", "Helper", updatedAt: 800, family: team)
  }

  @Test("The nests to join: one row of each other family the viewer owns and keeps")
  func destinations() {
    let archived = SessionSummary(
      id: "old", title: "Old", isArchived: true,
      family: SessionFamilyInfo(id: "old", representativeID: "old"))
    let theirs = SessionSummary(
      id: "theirs", title: "Theirs", family: SessionFamilyInfo(id: "theirs"))
    let sessions = [
      Self.helper, FamilyFixture.implementation, FamilyFixture.solo, Self.lead,
      FamilyFixture.coordinator, archived, theirs,
    ]
    let shared: (String) -> Bool = { $0 == "theirs" }
    let forSolo = SidebarFamilies.nestDestinations(
      for: FamilyFixture.solo, among: sessions, isShared: shared)
    // A family stands where its first row does, as its representative once that is loaded.
    #expect(forSolo.map(\.id) == ["lead", "coord"])
    let forReview = SidebarFamilies.nestDestinations(
      for: FamilyFixture.review, among: sessions, isShared: shared)
    #expect(forReview.map(\.id) == ["lead"], "its own nest is not a destination")
  }

  #if os(macOS)
    private func sidebar(canJoin: Bool = true) -> (SidebarSpy, OffscreenWindow<SidebarHarness>) {
      let state = FamilyFixture.state([
        FamilyFixture.coordinator, FamilyFixture.implementation, Self.lead, Self.helper,
        FamilyFixture.solo,
      ])
      let spy = SidebarSpy(state)
      var actions = spy.actions
      actions.sessions.moveToNest = { [spy] session, destination in
        spy.calls.append("nest \(session.id) \(destination?.id ?? "none")")
      }
      actions.sessions.canJoinNests = canJoin
      return (
        spy, OffscreenWindow(SidebarHarness(spy: spy, actions: actions), width: 300, height: 700)
      )
    }

    /// The first row's Nests submenu that `matches`.
    private func nests(
      in screen: OffscreenWindow<SidebarHarness>, where matches: (NSMenu) -> Bool
    ) throws -> NSMenu {
      let list = try #require(screen.list)
      for row in 0..<list.numberOfRows {
        if let menu = try screen.menu(ofRow: row),
          let nests = menu.item(named: "Move session")?.submenu?.item(named: "Nests")?.submenu,
          matches(nests)
        {
          return nests
        }
      }
      throw OffscreenWindowError.notFound("a matching Nests menu")
    }

    @Test("A session joins another nest from Move session, Nests")
    func joinsANest() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      // Only the standalone session has no nest to leave.
      let menu = try nests(in: screen) { $0.item(named: "Remove from nest") == nil }
      #expect(menu.item(named: "Coordinator") != nil)
      try screen.choose("Team lead", in: menu)
      #expect(spy.calls.last == "nest solo lead")
    }

    @Test("A nested session leaves its nest, and lists only the others")
    func leavesItsNest() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      // A row of the team's nest lists the other nest, not its own.
      let menu = try nests(in: screen) { $0.item(named: "Coordinator") != nil }
      #expect(menu.item(named: "Team lead") == nil)
      try screen.choose("Remove from nest", in: menu)
      #expect(["nest lead none", "nest helper none"].contains(spy.calls.last ?? ""))
    }

    @Test("Where sessions can't join nests, a nested one can still leave")
    func leaveOnly() throws {
      let (spy, screen) = sidebar(canJoin: false)
      defer { screen.close() }
      let menu = try nests(in: screen) { $0.item(named: "Remove from nest") != nil }
      #expect(menu.item(named: "Coordinator") == nil && menu.item(named: "Team lead") == nil)
      try screen.choose("Remove from nest", in: menu)
      #expect(spy.calls.last?.hasSuffix(" none") == true)
    }
  #endif
}
