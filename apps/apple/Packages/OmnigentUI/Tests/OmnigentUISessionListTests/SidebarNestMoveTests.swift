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

  @Test("The picker matches loaded nests by title, then adds the server's while they answer")
  func searchedDestinations() {
    let far = SessionSummary(
      id: "far", title: "Lead review",
      family: SessionFamilyInfo(id: "far", representativeID: "far", representativeTitle: "Far"))
    let loaded = [Self.lead, FamilyFixture.coordinator]
    let results = NestSearchResults(found: [far, Self.helper], query: "LEAD")
    let matched = NestPickerSheet.destinations(
      for: FamilyFixture.solo, local: loaded, results: results, query: " LEAD ",
      isShared: { _ in false })
    // The coordinator's title doesn't match; the helper's nest is the lead's, already listed.
    #expect(matched.map(\.id) == ["lead", "far"])
    let typing = NestPickerSheet.destinations(
      for: FamilyFixture.solo, local: loaded, results: results, query: "lea",
      isShared: { _ in false })
    #expect(typing.map(\.id) == ["lead"], "the server's matches for older text wait")
    let all = NestPickerSheet.destinations(
      for: FamilyFixture.solo, local: loaded, results: NestSearchResults(), query: "",
      isShared: { _ in false })
    #expect(all.map(\.id) == ["lead", "coord"])
  }

  // The spy and the drop handler's harness are the Mac's.
  #if os(macOS)
    @Test("A drag joins a row's nest or leaves its own; others' sessions and own nests refuse")
    func dragsBetweenNests() {
      let theirs = SessionSummary(
        id: "theirs", title: "Theirs", family: SessionFamilyInfo(id: "theirs"))
      var state = FamilyFixture.state([Self.lead, Self.helper, FamilyFixture.solo, theirs])
      state.rowInfo = ["theirs": SessionRowInfo(isShared: true)]
      let spy = SidebarSpy(state)
      var actions = spy.actions
      actions.sessions.moveToNest = { [spy] session, destination in
        spy.calls.append("nest \(session.id) \(destination?.id ?? "none")")
      }
      actions.sessions.canJoinNests = true
      let handler = SidebarDropHandler(state: state, actions: actions)
      // A nested member drags only because it can move between nests; the lead's row takes it.
      #expect(handler.rowDrag(Self.helper, movesWithFamily: true).payload != nil)
      #expect(handler.rowDrag(Self.lead, movesWithFamily: false).joinsNest)
      #expect(!handler.rowDrag(FamilyFixture.solo, movesWithFamily: false).joinsNest)
      #expect(handler.rowDrag(theirs, movesWithFamily: true).payload == nil)
      #expect(handler.drop(.session("solo"), on: .nest(Self.lead)))
      #expect(!handler.drop(.session("helper"), on: .nest(Self.lead)), "its own nest")
      #expect(!handler.drop(.session("theirs"), on: .nest(Self.lead)))
      #expect(handler.leavesNest("helper") && !handler.leavesNest("solo"))
      #expect(handler.drop(.session("helper"), on: .leaveNest))
      #expect(!handler.drop(.session("solo"), on: .leaveNest), "it is in no nest")
      // Dropped on a row outside its nest, a nested member leaves it; on its own nest, nothing.
      #expect(
        handler.rowDrop(.session("helper"), on: FamilyFixture.solo, zone: .row, target: .sessions))
      #expect(!handler.rowDrop(.session("helper"), on: Self.lead, zone: .row, target: .sessions))
      #expect(handler.rowDrop(.session("solo"), on: Self.lead, zone: .nest, target: .sessions))
      #expect(
        spy.calls == ["nest solo lead", "nest helper none", "nest helper none", "nest solo lead"])

      actions.sessions.canJoinNests = false
      let leaveOnly = SidebarDropHandler(state: state, actions: actions)
      #expect(!leaveOnly.rowDrag(Self.lead, movesWithFamily: false).joinsNest)
      #expect(!leaveOnly.drop(.session("solo"), on: .nest(Self.lead)))
    }

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
      actions.sessions.searchNests = { [spy] session in spy.calls.append("search \(session.id)") }
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

    @Test("Search Nests opens the server search for the row's session")
    func searchesNests() throws {
      let (spy, screen) = sidebar()
      defer { screen.close() }
      let menu = try nests(in: screen) { $0.item(named: "Remove from nest") == nil }
      try screen.choose("Search Nests\u{2026}", in: menu)
      #expect(spy.calls.last == "search solo")
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
      #expect(menu.item(named: "Search Nests\u{2026}") == nil)
      try screen.choose("Remove from nest", in: menu)
      #expect(spy.calls.last?.hasSuffix(" none") == true)
    }
  #endif
}
