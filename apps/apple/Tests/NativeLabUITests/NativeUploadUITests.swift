import XCTest

@MainActor
final class NativeUploadUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-test-upload-fixtures"]
    app.launch()
    XCTAssertTrue(app.staticTexts["Offline attachment fixtures"].waitForExistence(timeout: 5))
  }

  override func tearDownWithError() throws {
    app.terminate()
    app = nil
  }

  func testDraftFilesAndTextSurviveSessionSwitchAndRejectedSend() {
    let text = app.textFields["upload-fixture-text"]
    text.tap()
    text.typeText("keep this text")
    app.buttons["upload-fixture-add"].tap()
    XCTAssertTrue(app.staticTexts["Uploaded · Ready to send"].waitForExistence(timeout: 3))
    app.segmentedControls["upload-fixture-session"].buttons["B"].tap()
    XCTAssertFalse(app.buttons["attachment-remove-notes.txt"].exists)
    app.segmentedControls["upload-fixture-session"].buttons["A"].tap()
    XCTAssertEqual(text.value as? String, "keep this text")
    XCTAssertTrue(app.buttons["attachment-remove-notes.txt"].exists)
    app.switches["upload-fixture-reject"].tap()
    app.buttons["upload-fixture-send"].tap()
    XCTAssertTrue(app.buttons["attachment-remove-notes.txt"].exists)
    XCTAssertEqual(text.value as? String, "keep this text")
    app.switches["upload-fixture-reject"].tap()
    app.buttons["upload-fixture-send"].tap()
    XCTAssertFalse(app.buttons["attachment-remove-notes.txt"].exists)
    XCTAssertEqual(app.staticTexts["upload-fixture-attempts"].label, "Send attempts: 2")
  }

  func testAttachmentOnlySendAndUncertainUploadNeverSendsOrRetries() {
    app.buttons["upload-fixture-add"].tap()
    XCTAssertTrue(app.staticTexts["Uploaded · Ready to send"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["upload-fixture-send"].isEnabled)
    app.buttons["upload-fixture-send"].tap()
    XCTAssertFalse(app.buttons["attachment-remove-notes.txt"].exists)
    app.buttons["upload-fixture-uncertain"].tap()
    XCTAssertTrue(
      app.staticTexts["attachment-uncertain-uncertain.txt"].waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["attachment-retry-uncertain.txt"].exists)
    XCTAssertFalse(app.buttons["upload-fixture-send"].isEnabled)
    XCTAssertEqual(app.staticTexts["upload-fixture-attempts"].label, "Send attempts: 1")
  }

  func testCancelUploadKeepsFileAndShowsUnknownOutcome() {
    app.buttons["upload-fixture-slow"].tap()
    let cancel = app.buttons["attachment-cancel-slow.txt"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 3))
    cancel.tap()
    XCTAssertTrue(app.staticTexts["attachment-uncertain-slow.txt"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["attachment-remove-slow.txt"].exists)
    XCTAssertFalse(app.buttons["attachment-retry-slow.txt"].exists)
    XCTAssertFalse(app.buttons["upload-fixture-send"].isEnabled)
    XCTAssertEqual(app.staticTexts["upload-fixture-attempts"].label, "Send attempts: 0")
  }
}
