import XCTest

// Shared by OmnigentMacUITests (Developer ID, OMNIGENT_CHROMIUM) and
// OmnigentMacAppStoreUITests (App Store). Neither needs a server.

final class OmnigentMacUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testLaunchShowsConnectForm() {
    let app = XCUIApplication()
    app.launch()

    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["connect.button"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["connect.serverURL"].exists)
  }

  @MainActor
  func testNewWindowCommandOpensAWindow() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["connect.button"].waitForExistence(timeout: 10))
    let before = app.windows.count

    // File > New Window is Shift-Command-N; Command-N is New Session, as in the Electron app.
    app.typeKey("n", modifierFlags: [.command, .shift])

    let more = NSPredicate(format: "count > %d", before)
    expectation(for: more, evaluatedWith: app.windows)
    waitForExpectations(timeout: 10)
  }

  @MainActor
  func testSettingsOffersTheEditionsBrowserEngines() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.buttons["connect.button"].waitForExistence(timeout: 10))

    app.typeKey(",", modifierFlags: .command)
    let picker = app.popUpButtons["settings.browserEngine"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    picker.click()

    XCTAssertTrue(app.menuItems["System (WebKit)"].waitForExistence(timeout: 5))
    #if OMNIGENT_CHROMIUM
      XCTAssertTrue(app.menuItems["Chromium"].exists)
    #else
      XCTAssertFalse(app.menuItems["Chromium"].exists)
    #endif
    app.typeKey(.escape, modifierFlags: [])
  }
}
