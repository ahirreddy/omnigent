import XCTest

/// Answers decisions end to end against the core's offline demo server (`-OmnigentDemo`): an
/// approval and a single-choice question, through the decision dock, the store and the core's
/// resolve route. No server or network is needed.
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
    let approve = app.buttons["approval-approve-decision-design"].firstMatch
    XCTAssertTrue(approve.waitForExistence(timeout: 20), "the approval card did not show")
    save(window, "approval-pending")
    // The dock's identifier also lands on its scroll view, so click the button's own frame.
    approve.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: approve)
    waitForExpectations(timeout: 20)
    save(window, "approval-answered")

    open("demo-question", app: app, window: window)
    let option = app.buttons["decision-option-decision-question-0"].firstMatch
    XCTAssertTrue(option.waitForExistence(timeout: 20), "the question card did not show")
    save(window, "question-pending")
    option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: option)
    waitForExpectations(timeout: 20)
    save(window, "question-answered")
  }

  @MainActor
  private func open(_ sessionID: String, app: XCUIApplication, window: XCUIElement) {
    // The row is a text or, when it has hover actions, a button; the list's scroll view may
    // repeat the identifier.
    let row = window.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier == %@ AND elementType != %d", "session-row-\(sessionID)",
        XCUIElement.ElementType.scrollView.rawValue)
    ).firstMatch
    XCTAssertTrue(
      row.waitForExistence(timeout: 30),
      "the demo session \(sessionID) is missing from\n\(app.debugDescription)")
    let header = app.descendants(matching: .any)["session-header"]
    for _ in 0..<5 {
      window.click()
      row.click()
      if header.waitForExistence(timeout: 4) { break }
    }
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
