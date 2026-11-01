import XCTest

final class OmnigentUITests: XCTestCase {
  @MainActor
  func testLaunchShowsConnectForm() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.buttons["connect.button"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["connect.serverURL"].exists)
  }
}
