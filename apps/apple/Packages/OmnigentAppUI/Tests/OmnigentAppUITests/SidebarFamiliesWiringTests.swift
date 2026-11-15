import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// Session families through the connected window: the rows, the folders, the collapsed state
/// and the palette.
@MainActor
@Suite("Sidebar families: the connected window", .serialized, .timeLimit(.minutes(1)))
struct SidebarFamiliesWiringTests {
  private func row(_ id: String, updatedAt: Int, created: Int, extra: String) -> String {
    #"{"id":"\#(id)","title":"\#(id)","status":"idle","created_at":\#(created),"updated_at":\#(updatedAt),"host_id":"mac","workspace":"/w","permission_level":4,"archived":false\#(extra)}"#
  }

  /// `conv_a` leads a family with `conv_b`, both filed in Alpha when `filed`; `conv_c` stands
  /// alone. In the list's order `conv_b` is first, so the family stands first.
  private func familyServer(pinned: Bool = false, filed: Bool = false) -> AppServer {
    let server = newSessionServer()
    let project = filed ? #","project_id":"p1""# : ""
    let pinnedAt = pinned ? #","pinned_at":"7""# : ""
    let family =
      #","family":{"id":"conv_a","representative_id":"conv_a","representative_title":"Lead","pinned":\#(pinned)\#(pinnedAt)}"#
    let pin = pinned ? #","labels":{"omnigent.pinned":"7"}"# : ""
    let rows = [
      row("conv_b", updatedAt: 30, created: 2, extra: project + family),
      row("conv_c", updatedAt: 25, created: 3, extra: ""),
      row("conv_a", updatedAt: 20, created: 1, extra: project + family + pin),
    ]
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
    for (id, row) in zip(["conv_b", "conv_c", "conv_a"], rows) {
      server.route("/v1/sessions/\(id)", .json(row))
    }
    server.route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    return server
  }

  @Test("Bulk move files a family through its representative, and refuses a member alone")
  func bulkMove() async throws {
    let server = familyServer()
    let session = try await signedInSession(server)
    try await eventually("the projects") { !session.connection.sessionList.projects.isEmpty }
    let view = connectedView(session, WindowSelection())
    let rows = Dictionary(
      uniqueKeysWithValues: view.sidebarState.list.sessions.map { ($0.id, $0) })
    let lead = try #require(rows["conv_a"])
    let member = try #require(rows["conv_b"])
    let loose = try #require(rows["conv_c"])
    let actions = view.sidebarActions
    #expect(!actions.canMoveTogether([member, loose]))
    #expect(actions.canMoveTogether([lead, member, loose]))

    let alpha = SessionProject(id: "p1", name: "Alpha", sessionIds: [], projectID: "p1")
    actions.moveMany?([member, loose], alpha)
    let list = session.connection.sessionList
    try await eventually("the refusal") { list.editRetry != nil }
    #expect(try server.patched("/v1/sessions/conv_c").isEmpty, "refused before any request")
    list.dismissEditError()

    actions.moveMany?([lead, member], alpha)
    try await eventually("the move") { !server.requests("PATCH", "/v1/sessions/conv_a").isEmpty }
    #expect(try server.patched("/v1/sessions/conv_a").last?["project_id"] as? String == "p1")
    #expect(try server.patched("/v1/sessions/conv_b").isEmpty, "it moves with its representative")
  }

  @Test("Rows carry their family, and a pinned family shows whole in Pinned, out of its folder")
  func pinnedFamilyLeavesItsFolder() async throws {
    let session = try await signedInSession(familyServer(pinned: true, filed: true))
    let view = connectedView(session, WindowSelection())
    try await eventually("the folder") { !view.sidebarState.projects.isEmpty }
    let state = view.sidebarState
    #expect(
      state.list.sessions.first { $0.id == "conv_b" }?.family
        == SessionFamilyInfo(
          id: "conv_a", representativeID: "conv_a", representativeTitle: "Lead", isPinned: true,
          pinnedAt: "7"))
    #expect(
      SidebarNavigationOrder.pinnedIDs(state, defaults: try scratchDefaults()) == [
        "conv_a", "conv_b",
      ])
    #expect(state.projects.first?.sessionIds.isEmpty == true)
    #expect(state.pinnedCount == 1, "the family takes one pin slot")
  }

  @Test("Collapsing a family takes its members out of Next and Previous until it expands")
  func collapsedFamilySkipsMembers() async throws {
    let session = try await signedInSession(familyServer())
    let selection = WindowSelection(.session("conv_a"))
    let view = connectedView(session, selection)
    view.navigation(from: "conv_a").nextSession?()
    #expect(selection.page == .session("conv_b"))

    let key = SidebarFamilyScope.section("Sessions").key(family: "conv_a")
    view.sidebarActions.setFamilyCollapsed?(key, true)
    #expect(view.sidebarModel.collapsedFamilies == [key])
    #expect(view.sidebarState.collapsedFamilies == [key])
    view.navigation(from: "conv_a").nextSession?()
    #expect(selection.page == .session("conv_c"))

    view.sidebarActions.setFamilyCollapsed?(key, false)
    #expect(view.sidebarState.collapsedFamilies.isEmpty)
  }

  @Test("A nested session's palette row names its project and the session it's nested under")
  func paletteBreadcrumbs() async throws {
    let session = try await signedInSession(familyServer(filed: true))
    try await eventually("the projects") { !session.connection.sessionList.projects.isEmpty }
    let adapter = PaletteAdapter(session: session, selection: WindowSelection().binding)
    let crumbs = Dictionary(
      uniqueKeysWithValues: adapter.state.sessions.map { ($0.id, $0.breadcrumb) })
    #expect(crumbs["session-conv_b"] == PaletteBreadcrumb(project: "Alpha", parent: "Lead"))
    #expect(crumbs["session-conv_a"] == .some(nil))
    #expect(crumbs["session-conv_c"] == .some(nil))
    let found = await adapter.searchServer("conv", limit: 5)
    #expect(
      found.titles.first { $0.id == "found-conv_b" }?.breadcrumb
        == PaletteBreadcrumb(project: "Alpha", parent: "Lead"))
  }

  @Test("The adapter shows a member pinned with its family, never by a pin of its own")
  func adapterPinRule() {
    let family = OmnigentCoreFFI.SessionFamily(
      id: "lead", representativeId: "lead", representativeTitle: "Lead", pinned: false,
      pinnedAt: nil)
    func summary(_ id: String, pinned: Bool) -> OmnigentCoreFFI.SessionSummary {
      OmnigentCoreFFI.SessionSummary(
        id: id, title: id, preview: "", status: .idle, pendingRequests: 0, isReadOnly: false,
        updatedAt: 0, workspace: "/w", agentName: "", isPinned: pinned, isArchived: false,
        permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true,
        canArchive: true, configuration: nil, terminalFirst: false, createdAt: 5, owner: nil,
        projectId: nil, projectLabel: nil, canStop: false, family: family)
    }
    let lone = OmnigentCoreFFI.SessionSummary(
      id: "lone", title: "lone", preview: "", status: .idle, pendingRequests: 0,
      isReadOnly: false, updatedAt: 0, workspace: "/w", agentName: "", isPinned: true,
      isArchived: false, permissionLevel: 4, failureMessage: nil, canRename: true, canPin: true,
      canArchive: true, configuration: nil, terminalFirst: false, createdAt: 5, owner: nil,
      projectId: nil, projectLabel: nil, canStop: false)
    #expect(
      SidebarAdapter.shownPinned([summary("lead", pinned: false), summary("member", pinned: true)])
        .isEmpty)
    #expect(
      SidebarAdapter.shownPinned([summary("lead", pinned: true), summary("member", pinned: false)])
        == ["lead", "member"])
    #expect(SidebarAdapter.shownPinned([lone]) == ["lone"])
  }
}
