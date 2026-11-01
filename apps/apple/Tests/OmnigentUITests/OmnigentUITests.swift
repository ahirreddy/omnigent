import XCTest

final class OmnigentUITests: XCTestCase {
  @MainActor
  func testLaunchShowsConnectForm() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.buttons["auth.connect"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["auth.server-url"].exists)
  }
}
