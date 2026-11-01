import XCTest

/// Password sign-in, credential restore after a relaunch, and sign-out against an accounts-mode
/// server. Skipped unless the runner gets `OMNIGENT_E2E_ACCOUNTS_URL`, `OMNIGENT_E2E_USERNAME`
/// and `OMNIGENT_E2E_PASSWORD` (with the `TEST_RUNNER_` prefix), which must be test values for
/// that server only.
final class AccountsSignInUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testPasswordSignInRestoreAndSignOut() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_ACCOUNTS_URL"],
      let username = environment["OMNIGENT_E2E_USERNAME"],
      let password = environment["OMNIGENT_E2E_PASSWORD"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_ACCOUNTS_URL, _USERNAME and _PASSWORD to run.")
    }
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    let window = app.windows.firstMatch

    let usernameField = app.textFields["auth.username"]
    XCTAssertTrue(usernameField.waitForExistence(timeout: 30), "no password form")
    save(window, "password-form")
    usernameField.click()
    usernameField.typeText(username)
    let passwordField = app.secureTextFields["auth.password"]
    passwordField.click()
    passwordField.typeText(password)
    app.buttons["auth.sign-in"].click()
    // The session list (an outline) carries `sidebar` once the connected window shows.
    let sidebar = app.outlines["sidebar"]
    let signedIn = sidebar.waitForExistence(timeout: 30)
    save(window, "signed-in")
    XCTAssertTrue(signedIn, "did not sign in")

    // The credential is kept by the core in the Keychain and restored on the next launch.
    app.terminate()
    app.launch()
    XCTAssertTrue(sidebar.waitForExistence(timeout: 30), "the saved sign-in was not restored")
    save(app.windows.firstMatch, "restored")

    let chip = app.descendants(matching: .any)["auth.account-chip"].firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 10))
    chip.click()
    let signOut = app.descendants(matching: .any)["auth.sign-out"].firstMatch
    XCTAssertTrue(signOut.waitForExistence(timeout: 10))
    signOut.click()
    XCTAssertTrue(
      app.textFields["auth.username"].waitForExistence(timeout: 30)
        || app.buttons["auth.connect"].waitForExistence(timeout: 5),
      "sign-out did not return to sign-in")
    save(app.windows.firstMatch, "signed-out")
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
