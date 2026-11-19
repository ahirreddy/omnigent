import XCTest

/// Saved workflows on the local server, with the real pointer: the sidebar's Workflows row opens
/// the page, a workflow's card opens its page with its plan, and Run starts a session that runs
/// it. Needs a server started with `OMNIGENT_FEATURES=workflows`.
final class MacWorkflowsFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testWorkflowsOpenAWorkflowAndRunIt() async throws {
    let live = MacLiveUITestSupport(self)
    let info = try await live.serverJSON("GET", "/v1/info")
    let features = info["features"] as? [String: Any]
    try XCTSkipUnless(
      info["workflows"] as? Bool == true && features?["workflows"] as? Bool == true,
      "the server has workflows off")
    let name = "UI flow workflow \(UUID().uuidString.prefix(6))"
    let workflow = try await live.serverJSON(
      "POST", "/v1/workflows",
      body: [
        "name": name, "description": "Rerun the suite and file an issue for each flaky test.",
        "steps": [
          ["id": "rerun", "name": "Rerun the suite", "depends_on": [String]()],
          ["id": "file", "name": "File issues", "depends_on": ["rerun"]],
        ],
      ])
    let id = try XCTUnwrap(workflow["id"] as? String, "\(workflow)")
    live.removeAfterTheTest("/v1/workflows/\(id)")
    let app = live.launch()
    defer { app.terminate() }

    // The sidebar's row opens the page, which lists the workflow.
    let row = live.element("sidebar-workflows", in: app)
    XCTAssertTrue(row.appears(within: 30), "the sidebar has no Workflows row")
    live.click(row, "Workflows")
    let card = live.element("workflow-\(id)", in: app)
    XCTAssertTrue(card.appears(within: 20), "the workflow is not listed")
    live.shot(app, "the Workflows page")

    // Its card opens its page, with its plan as a graph.
    live.click(card, "the workflow's card")
    XCTAssertTrue(
      live.element("workflow-detail-title", in: app).appears(within: 15),
      "the card did not open the workflow")
    XCTAssertTrue(
      live.element("workflow-step-rerun", in: app).appears(within: 10), "the plan has no steps")
    live.shot(app, "the workflow's page")

    // Run opens the new-session page set to run it; a start sends the run's request.
    live.click(live.element("workflow-detail-run", in: app), "Run")
    XCTAssertTrue(
      live.element("new-session-workflow", in: app).appears(within: 15),
      "Run did not open the new-session page for the workflow")
    XCTAssertTrue(
      live.text(containing: "Run \u{201C}\(name)\u{201D}", in: app).appears(within: 5),
      "the page does not name the workflow")
    live.shot(app, "the run's new-session page")
    live.send("Only the upload tests", in: app)
    XCTAssertTrue(
      live.text(containing: "Use the workflow skill to run the saved workflow", in: app)
        .appears(within: 30),
      "the session did not get the run's request")
    live.shot(app, "the run's session")
  }
}
