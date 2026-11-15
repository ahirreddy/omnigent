import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// The bulk bar's Move to project with session families: only representatives are written.
@MainActor
@Suite("Family moves", .timeLimit(.minutes(1)))
struct SessionListFamilyMoveTests {
  /// A row of the `lead` family (or a standalone row without `representative`) in `project`.
  private func row(_ id: String, representative: String?, project: String = "p0") -> String {
    let family =
      representative.map {
        #","family":{"id":"lead","representative_id":"\#($0)","pinned":false}"#
      } ?? ""
    return
      #"{"id":"\#(id)","status":"idle","created_at":1,"updated_at":2,"permission_level":4,"project_id":"\#(project)"\#(family)}"#
  }

  private func server() -> RouteServer {
    let server = RouteServer()
    let rows = [
      row("lead", representative: "lead"), row("peer", representative: "lead"),
      row("solo", representative: nil),
    ]
    server.route(
      "/v1/sessions",
      .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
    server.route("/v1/sessions/projects", .json(#"[{"id":"p1","name":"Alpha"}]"#))
    server.route(
      "/v1/sessions/lead", method: "PATCH",
      .json(row("lead", representative: "lead", project: "p1")))
    server.route(
      "/v1/sessions/solo", method: "PATCH", .json(row("solo", representative: nil, project: "p1")))
    server.route(
      "/v1/sessions/peer", method: "GET", .json(row("peer", representative: "lead", project: "p1")))
    return server
  }

  @Test("A member moves with its representative; alone it refuses the whole selection")
  func bulkMove() async throws {
    let server = server()
    let store = try await connectedStore(server)
    let list = store.sessionList
    try await eventually("the family") { list.session("peer") != nil && !list.projects.isEmpty }
    let alpha = list.projects[0]
    let patches = { (id: String) in server.requests(to: "/v1/sessions/\(id)", method: "PATCH") }

    let refused = await list.move(["peer", "solo"], to: alpha)
    #expect(refused == ["peer", "solo"])
    #expect(list.editError != nil)
    #expect(patches("peer").isEmpty && patches("solo").isEmpty)

    let unmoved = await list.move(["peer", "lead", "solo"], to: alpha)
    #expect(unmoved.isEmpty)
    #expect(list.editError == nil)
    #expect(patches("lead").count == 1 && patches("solo").count == 1)
    #expect(patches("peer").isEmpty, "the representative carries its member")
    #expect(list.session("peer")?.projectId == "p1")
  }
}
