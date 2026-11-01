import XCTest

final class OmnigentMacUITests: XCTestCase {
  @MainActor
  func testLaunchShowsConnectForm() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["connect.button"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["connect.serverURL"].exists)
  }
}
