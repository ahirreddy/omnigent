import XCTest

/// A sub-agent's request, mirrored into its parent session on the local server: shown there as
/// the sub-agent's, answered there, and delivered to the sub-agent.
final class MacSubagentRequestFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A question a sub-agent asks shows in its parent marked as the sub-agent's and makes the
  /// parent need you; the answer chosen there resolves the request on the sub-agent.
  @MainActor
  func testAnsweringASubagentQuestionFromTheParent() async throws {
    let live = MacLiveUITestSupport(self)
    let parent = try live.fixtureSession()
    let parentSession = try await live.serverJSON("GET", "/v1/sessions/\(parent)")
    let agent = try XCTUnwrap(parentSession["agent_id"] as? String, "\(parentSession)")
    let created = try await live.serverJSON(
      "POST", "/v1/sessions",
      body: ["agent_id": agent, "parent_session_id": parent, "title": "Release notes helper"])
    let child = try XCTUnwrap(created["id"] as? String, "\(created)")
    // The child's MCP server asks; the server mirrors the request into the parent.
    let asked = try await live.serverJSON(
      "POST", "/v1/sessions/\(child)/events",
      body: [
        "type": "mcp_elicitation",
        "data": [
          "message": "Ship the release notes now?",
          "requestedSchema": [
            "type": "object",
            "properties": ["answer": ["type": "string", "enum": ["Ship", "Hold"]]],
          ],
        ],
      ])
    let request = try XCTUnwrap(asked["elicitation_id"] as? String, "\(asked)")
    removeAfterTheTest(child, request: request, on: live.server)

    let app = live.launch()
    defer { app.terminate() }
    live.open(parent, in: app)
    let ship = live.elements(prefix: "decision-option-\(request)-0", in: app).firstMatch
    XCTAssertTrue(ship.appears(within: 30), "the mirrored question is missing")
    XCTAssertTrue(
      live.text(containing: "From a subagent", in: app).exists, "the card is not the sub-agent's")
    live.assertRow(parent, in: app, contains: "Needs you")

    live.click(ship, "Ship")
    XCTAssertTrue(ship.disappears(within: 15), "the question stayed")
    live.assertRow(parent, in: app, contains: "Needs you", false)
    let status = try await live.serverJSON(
      "GET", "/v1/sessions/\(child)/elicitations/\(request)")
    XCTAssertEqual(status["status"] as? String, "resolved", "the sub-agent still waits: \(status)")
  }

  /// Once the flow ends, pass or fail, dismisses the child's request (so the shared fixture
  /// session does not keep needing you) and deletes the child.
  private func removeAfterTheTest(_ child: String, request: String, on server: String) {
    guard let session = URL(string: "\(server)/v1/sessions/\(child)") else {
      XCTFail("no URL for \(child) on \(server)")
      return
    }
    let resolve = session.appending(path: "elicitations/\(request)/resolve")
    addTeardownBlock {
      var dismiss = URLRequest(url: resolve)
      dismiss.httpMethod = "POST"
      dismiss.setValue("application/json", forHTTPHeaderField: "Content-Type")
      dismiss.httpBody = Data(#"{"action":"cancel"}"#.utf8)
      // Already answered when the flow passed; the server then refuses it, which is fine.
      _ = try? await URLSession.shared.data(for: dismiss)
      var delete = URLRequest(url: session)
      delete.httpMethod = "DELETE"
      let (_, response) = try await URLSession.shared.data(for: delete)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      XCTAssertTrue((200..<300).contains(status), "deleting \(child) answered \(status)")
    }
  }
}
