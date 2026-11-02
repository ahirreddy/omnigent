import XCTest

/// Answers decisions end to end against the core's offline demo server (`-OmnigentDemo`): an
/// approval and a single-choice question, through the decision dock, the store and the core's
/// resolve route. No server or network is needed.
///
/// A pending card answers from one surface at a time: inline while it is on screen, with the
/// dock reduced to its one-line summary, else from the dock (`dock-`-prefixed identifiers).
final class DemoDecisionUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testApprovalAndQuestionResolveThroughTheCore() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OmnigentDemo", "YES", "-desktop.defaultServerURL", "http://127.0.0.1:6767",
      "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    let window = app.windows.firstMatch

    open("demo-design", app: app, window: window)
    // The payload-first card in the transcript holds Approve; while it is on screen the dock
    // only names the request and offers no second Approve.
    let inlineApprove = app.buttons["approval-approve-decision-design"]
    XCTAssertTrue(inlineApprove.waitForExistence(timeout: 20), "the approval card did not show")
    let dockSummary = window.descendants(matching: .any)["decision-dock-summary"]
    XCTAssertTrue(dockSummary.waitForExistence(timeout: 10), "the dock did not collapse")
    XCTAssertFalse(
      app.buttons["dock-decision-open-decision-design"].exists, "the dock repeats the request")
    save(window, "approval-pending")
    // XCUITest cannot compute a hit point inside SwiftUI scroll views, so click the button found
    // by identifier at its center instead of asking XCUITest to scroll to it.
    inlineApprove.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    waitUntilGone(inlineApprove)
    waitUntilGone(dockSummary)
    save(window, "approval-answered")

    open("demo-question", app: app, window: window)
    let option = app.buttons["decision-option-decision-question-0"]
    XCTAssertTrue(option.waitForExistence(timeout: 20), "the question card did not show")
    XCTAssertFalse(
      app.buttons["dock-decision-option-decision-question-0"].exists,
      "the dock repeats the question's answers")
    save(window, "question-pending")
    option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    waitUntilGone(option)
    save(window, "question-answered")
  }

  @MainActor
  private func waitUntilGone(_ element: XCUIElement) {
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
    waitForExpectations(timeout: 20)
  }

  @MainActor
  private func open(_ sessionID: String, app: XCUIApplication, window: XCUIElement) {
    // The row is a text, or a button while the pointer is over it (its hover actions).
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(
      row.waitForExistence(timeout: 30),
      "the demo session \(sessionID) is missing from\n\(app.debugDescription)")
    let transcript = app.scrollViews["transcript-\(sessionID)"]
    // The first launch can lose focus to a system prompt as the row is clicked; click again.
    for _ in 0..<5 where !transcript.exists {
      window.click()
      row.click()
      _ = transcript.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(transcript.exists, "the session \(sessionID) did not open")
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
