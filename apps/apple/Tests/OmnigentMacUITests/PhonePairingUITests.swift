import XCTest

/// Settings › Phone shows a pairing code for the window's server. The pane's screenshot is kept
/// as a test attachment.
final class PhonePairingUITests: XCTestCase {
  @MainActor
  func testSettingsShowsThePairingCode() {
    let app = XCUIApplication()
    app.launchArguments += ["-OmnigentDemo"]
    app.launch()
    let any = app.descendants(matching: .any)
    XCTAssertTrue(
      any.matching(identifier: "server-switcher").firstMatch.waitForExistence(timeout: 20))

    app.typeKey(",", modifierFlags: .command)
    let phone = app.toolbars.buttons["Phone"]
    XCTAssertTrue(phone.waitForExistence(timeout: 10))
    phone.click()

    XCTAssertTrue(
      any.matching(identifier: "pairing.qr-code").firstMatch.waitForExistence(timeout: 10))
    // The demo server is loopback, which a phone can't reach.
    XCTAssertTrue(any.matching(identifier: "pairing.loopback-warning").firstMatch.exists)
    let window = app.windows.containing(.any, identifier: "pairing.settings").firstMatch
    let screenshot = window.exists ? window.screenshot() : app.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "settings-phone"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.typeKey("w", modifierFlags: .command)
  }
}
