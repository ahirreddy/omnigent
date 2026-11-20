import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentTestSupport
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A new automation files into "Omnigent Automation" where the server keeps projects, as the
/// web's default; a chosen project or none stays as chosen.
@MainActor
@Suite("Automations: the default project", .serialized, .timeLimit(.minutes(1)))
struct AutomationDefaultProjectTests {
  private func offered(projects: Bool) async throws -> ServerPages? {
    let server = newSessionServer()
    let connection = try await signedInStore(server)
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"automations_enabled":true,"scheduled_task_projects":\#(projects)}"#
      ))
    let pages = try #require(connection.pages)
    _ = await pages.loadOffered()
    return pages.offered
  }

  @Test("New automations file into the default project only where projects are kept")
  func defaultProject() async throws {
    let draft = AutomationDraftState(name: "Nightly", agentID: "a1")
    let filed = AutomationsMapping.withDefaultProject(
      draft, offered: try await offered(projects: true))
    #expect(filed.projectName == "Omnigent Automation" && filed.projectID.isEmpty)
    let unfiled = AutomationsMapping.withDefaultProject(
      draft, offered: try await offered(projects: false))
    #expect(unfiled.projectName == nil)
    var chosen = draft
    chosen.projectID = "p1"
    #expect(
      AutomationsMapping.withDefaultProject(chosen, offered: try await offered(projects: true))
        .projectName == nil)
  }
}
