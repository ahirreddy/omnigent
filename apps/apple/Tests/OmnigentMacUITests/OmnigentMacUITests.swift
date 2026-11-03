import XCTest

// Shared by OmnigentMacUITests (Developer ID, OMNIGENT_CHROMIUM) and
// OmnigentMacAppStoreUITests (App Store). Needs no server.
//
// UI automation drives the real mouse and keyboard and costs about a second per action, so this
// target keeps only what needs the real app process or real macOS input. Everything else is a
// package or hosted test (see AGENTS.md, "Mac tests without UI automation").

final class OmnigentMacUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// The app launches (with its helper processes) and shows the connect form.
  @MainActor
  func testLaunchShowsConnectForm() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["auth.connect"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["auth.server-url"].exists)
  }
}
