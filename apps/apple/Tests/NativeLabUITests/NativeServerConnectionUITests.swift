import XCTest

@MainActor
final class NativeServerConnectionUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-demo"]
    app.launch()
  }

  override func tearDownWithError() throws { app.terminate() }

  func testHostedSignInShowsSecureFieldsAndClearsThemWhenServerChanges() {
    setAddress("https://omni.example/api/team-a")
    let picker = app.buttons["server-auth-method"]
    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    picker.tap()
    app.buttons["Username and password"].tap()
    let username = app.textFields["server-username"]
    XCTAssertTrue(username.waitForExistence(timeout: 5))
    username.tap()
    username.typeText("alice")
    dismissKeyboard()
    let password = app.secureTextFields["server-password"]
    XCTAssertTrue(password.exists)
    password.tap()
    password.typeText("fixture-password")
    dismissKeyboard()
    setAddress("https://omni.example/api/team-b")
    XCTAssertEqual(password.value as? String, "Password")
    picker.tap()
    app.buttons["Access token"].tap()
    let token = app.secureTextFields["server-access-token"]
    XCTAssertTrue(token.waitForExistence(timeout: 5))
    token.tap()
    token.typeText("fixture-token")
    dismissKeyboard()
    setAddress("https://other.example")
    XCTAssertEqual(token.value as? String, "Access token")
    app.swipeUp()
    capture("hosted-sign-in-secure-fields")
  }

  func testNonlocalHTTPIsRejectedBeforeCredentialsAreSent() {
    setAddress("http://insecure.example")
    app.swipeUp()
    let connect = app.buttons["connect-local"]
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    connect.tap()
    let error = app.descendants(matching: .any)["connection-error"].firstMatch
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertTrue(error.label.contains("HTTPS"))
    XCTAssertFalse(app.otherElements["live-workspace-notice"].exists)
    capture("hosted-connection-rejects-insecure-address")
  }

  private func setAddress(_ value: String) {
    let field = app.textFields["local-server-url"]
    for _ in 0..<4 {
      if field.exists && field.isHittable { break }
      app.swipeDown()
    }
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    let clear = app.buttons["clear-server-url"]
    if clear.waitForExistence(timeout: 3) {
      clear.tap()
    }
    field.typeText(value)
    XCTAssertEqual(field.value as? String, value)
    dismissKeyboard()
    app.swipeUp()
  }

  private func dismissKeyboard() {
    let done = app.buttons["dismiss-server-keyboard"]
    XCTAssertTrue(done.waitForExistence(timeout: 3))
    done.tap()
    let hidden = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
    XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
