import XCTest

@MainActor
final class NativeCreationUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws { continueAfterFailure = false }
  override func tearDownWithError() throws {
    app?.terminate()
    app = nil
  }

  func testReadyHostRequiresAbsoluteWorkspaceAndPrompt() {
    launch("ready")
    XCTAssertFalse(app.buttons["create-session"].isEnabled)
    enter("relative/path", into: "creation-workspace")
    enter("Keep this isolated fixture local", into: "new-session-prompt")
    XCTAssertFalse(app.buttons["create-session"].isEnabled)
    enter("/fixture/project", into: "creation-workspace", replacing: true)
    XCTAssertTrue(app.buttons["create-session"].isEnabled)
    XCTAssertTrue(element("creation-host").exists)
    XCTAssertTrue(element("creation-harness").exists)
    XCTAssertTrue(element("creation-agent").exists)
    XCTAssertTrue(element("creation-model").isEnabled)
    reveal(element("creation-host"))
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = "creation-host-harness-model"
    image.lifetime = .keepAlways
    add(image)
  }

  func testUnconfiguredHostExplainsWhyCreationIsDisabled() {
    launch("not-ready")
    enter("/fixture/project", into: "creation-workspace")
    enter("Do not send this fixture", into: "new-session-prompt")
    let reason = element("creation-unavailable")
    reveal(reason)
    XCTAssertTrue(reason.label.contains("Sign in"))
    XCTAssertFalse(app.buttons["create-session"].isEnabled)
  }

  func testMissingModelCatalogStillAllowsHarnessDefault() {
    launch("models-unavailable")
    enter("/fixture/project", into: "creation-workspace")
    enter("Keep the harness default", into: "new-session-prompt")
    let notice = element("creation-model-notice")
    reveal(notice)
    XCTAssertTrue(notice.label.contains("Harness default remains available"))
    XCTAssertFalse(element("creation-model").isEnabled)
    XCTAssertTrue(app.buttons["create-session"].isEnabled)
  }

  func testUncertainCreationPreservesDraftAndRequiresReviewBeforeResubmission() {
    launch("uncertain")
    enter("/fixture/project", into: "creation-workspace")
    enter("Preserve this exact first message", into: "new-session-prompt")
    app.buttons["create-session"].tap()
    let review = app.buttons["creation-review-sessions"]
    reveal(review)
    XCTAssertTrue(review.exists)
    XCTAssertFalse(app.buttons["create-session"].isEnabled)
    let draft = element("new-session-prompt")
    reveal(draft)
    XCTAssertEqual(draft.value as? String, "Preserve this exact first message")
    XCTAssertFalse(draft.isEnabled)
    let acknowledge = app.buttons["creation-acknowledge-review"]
    reveal(acknowledge)
    acknowledge.tap()
    XCTAssertTrue(app.buttons["create-session"].isEnabled)
    reveal(draft)
    XCTAssertEqual(draft.value as? String, "Preserve this exact first message")
  }

  private func launch(_ scenario: String) {
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-demo", "--ui-test-creation=\(scenario)"]
    app.launch()
    XCTAssertTrue(app.buttons["open-demo"].waitForExistence(timeout: 10))
    app.buttons["open-demo"].tap()
    let newSession = app.buttons["new-session"]
    XCTAssertTrue(newSession.waitForExistence(timeout: 10))
    newSession.tap()
    XCTAssertTrue(element("creation-workspace").waitForExistence(timeout: 5))
  }

  private func enter(_ value: String, into id: String, replacing: Bool = false) {
    let field = element(id)
    reveal(field)
    field.tap()
    if replacing, let existing = field.value as? String {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    }
    field.typeText(value)
    let done = app.buttons["creation-dismiss-keyboard"]
    if done.waitForExistence(timeout: 2) { done.tap() }
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<6 {
      if element.exists && element.isHittable { return }
      app.swipeUp()
    }
    for _ in 0..<8 {
      if element.exists && element.isHittable { return }
      app.swipeDown()
    }
    XCTAssertTrue(element.exists, "Expected creation form control")
  }
}
