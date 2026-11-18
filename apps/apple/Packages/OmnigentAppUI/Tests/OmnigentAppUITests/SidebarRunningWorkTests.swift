import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// Archiving sessions, or deleting a project, whose agents are still working asks first, as the
/// web does; nothing is sent until the user says so.
@MainActor
@Suite("Running work confirmations", .serialized, .timeLimit(.minutes(1)))
struct SidebarRunningWorkTests {
  private let project = SessionProject(
    id: "p1", name: "Alpha", sessionIds: [], projectID: "p1", icon: nil)

  private static let running =
    #"{"id":"conv_r","status":"running","created_at":1,"updated_at":40,"host_id":"mac","workspace":"/r","permission_level":4,"agent_id":"ag_claude"}"#
  private static let idle =
    #"{"id":"conv_i","status":"idle","created_at":1,"updated_at":30,"host_id":"mac","workspace":"/i","permission_level":4,"agent_id":"ag_claude"}"#

  private func opened(_ rows: [String]) async throws -> (ConnectedServerView, AppServer) {
    let server = threeSessionServer()
    server.route(
      "/v1/sessions", method: "GET",
      .json(#"{"object":"list","data":[\#(rows.joined(separator: ","))],"has_more":false}"#))
    server.route("/v1/sessions/conv_r", .json(Self.running))
    server.route("/v1/sessions/conv_i", .json(Self.idle))
    let session = try await signedInSession(server)
    return (connectedView(session, WindowSelection()), server)
  }

  @Test("Archiving a session whose agent works asks first; only Archive sends it")
  func archivingARunningSession() async throws {
    let (view, server) = try await opened([Self.running, Self.idle])
    view.requestArchive(["conv_r", "conv_i"], archived: true)
    let request = try #require(view.sidebarModel.archiveRunningRequest)
    #expect(request.runningCount == 1)
    #expect(request.title == "Archive a running session?")
    #expect(try server.patched("/v1/sessions/conv_r").isEmpty, "nothing archives before Archive")

    view.sidebarModel.archiveRunningRequest = nil
    view.requestArchive(request.sessionIDs, archived: true, confirmedRunning: true)
    try await eventually("the archive") { (try? server.patched("/v1/sessions/conv_r").count) == 1 }
    #expect(try server.patched("/v1/sessions/conv_r").last?["archived"] as? Bool == true)

    // An idle session archives without asking.
    view.requestArchive(["conv_i"], archived: true)
    #expect(view.sidebarModel.archiveRunningRequest == nil)
  }

  @Test("Deleting a project whose agents work asks again, and deletes nothing until then")
  func deletingAWorkingProject() async throws {
    let (view, server) = try await opened([Self.running])
    server.route("/v1/projects/p1", method: "DELETE", .json(#"{"deleted":true}"#))
    view.sidebarActions.deleteProject?(project)
    try await eventually("the question") { view.sidebarModel.projectDeleteRunning != nil }
    let request = try #require(view.sidebarModel.projectDeleteRunning)
    #expect(request.runningCount == 1)
    #expect(request.message.hasPrefix("1 session in Alpha has an agent still working."))
    #expect(server.requests("DELETE", "/v1/projects/p1").isEmpty)
  }
}
