import Foundation
import OmnigentCoreFFI
import OmnigentTestSupport
import Testing

@testable import OmnigentStores

/// Saved workflows over a scripted server: the lists, a draft that opens its page, a run's Stop
/// until its session is seen idle, and the grants.
@MainActor
@Suite("Workflows store", .timeLimit(.minutes(1)))
struct WorkflowsStoreTests {
  private let id = "0123456789abcdef0123456789abcdef"
  private let session = "fedcba9876543210fedcba9876543210"
  private let runID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  private func server() -> RouteServer {
    let server = RouteServer()
    server.route(
      "/v1/info",
      .json(
        #"{"single_user":true,"accounts_enabled":false,"workflows":true,"features":{"workflows":true}}"#
      ))
    return server
  }

  private func workflow(_ name: String, draft: Bool = false) -> String {
    #"{"id":"\#(id)","name":"\#(name)","description":"Rerun the suite","created_at":1,"updated_at":2,"is_draft":\#(draft),"steps":[]}"#
  }

  private func runs(running: Bool) -> HttpResponse {
    let status = running ? "running" : "idle"
    return .json(
      #"{"data":[{"id":"\#(runID)","workflow_id":"\#(id)","session_id":"\#(session)","title":"Run","started_at":5,"is_current":true,"session_status":"\#(status)","progress":{"total":1},"steps":[{"id":"a","name":"A","depends_on":[]}],"statuses":[]}],"next_cursor":null}"#
    )
  }

  @Test("the lists read a page at a time, and a new draft asks its page to open")
  func listsAndDraft() async throws {
    let server = server()
    server.route(
      "/v1/workflows",
      .json(#"{"data":[\#(workflow("Triage"))],"has_more":true,"next_cursor":"n"}"#))
    let connection = try await connectedStore(server)
    let store = try #require(connection.workflows)
    await store.loadLists(sharing: false)
    #expect(store.owned.value?.map(\.name) == ["Triage"])
    #expect(store.ownedCursor == "n")
    #expect(server.requests(to: "/v1/workflows/shared").isEmpty, "not shared here")

    server.route("/v1/workflows", .json(workflow("New one", draft: true)))
    let result = await store.createDraft(name: "New one", description: "Do it")
    guard case .success(let draft) = result else {
      Issue.record("the draft was not saved: \(result)")
      return
    }
    #expect(draft.workflow.isDraft)
    #expect(store.requestedWorkflowID == id)
    #expect(store.details[id]?.value?.workflow.name == "New one")
  }

  @Test("Stop shows as stopping until the run's session is seen idle")
  func stopSettles() async throws {
    let server = server()
    let path = "/v1/workflows/\(id)/runs"
    server.route(path, runs(running: true))
    server.route("/v1/sessions/\(session)/events", .json(#"{"queued":false}"#))
    let connection = try await connectedStore(server)
    let store = try #require(connection.workflows)
    await store.loadRuns(id)
    let run = try #require(store.runs[id]?.value?.first)
    #expect(await store.stop(run, planName: "Triage", workflowID: id))
    #expect(store.stoppingRuns.contains(runID))
    let sent = try #require(server.requests(to: "/v1/sessions/\(session)/events").last)
    #expect(String(bytes: sent.body ?? Data(), encoding: .utf8)?.contains(runID) == true)
    server.route(path, runs(running: false))
    await store.loadRuns(id)
    #expect(!store.stoppingRuns.contains(runID), "the run stopped")
  }

  @Test("A session's current run of a workflow is read by session, for the runs below it")
  func sessionRun() async throws {
    let server = server()
    server.route("/v1/workflows/\(id)/runs", runs(running: true))
    let connection = try await connectedStore(server)
    let store = try #require(connection.workflows)
    await store.loadSessionRun(workflowID: id, sessionID: session)
    let key = WorkflowsStore.sessionRunKey(workflowID: id, sessionID: session)
    #expect(store.sessionRuns[key]?.id == runID)
    let read = try #require(server.requests(to: "/v1/workflows/\(id)/runs").last)
    #expect(URLComponents(string: read.url)?.queryItems?.contains { $0.value == session } == true)
  }
}
