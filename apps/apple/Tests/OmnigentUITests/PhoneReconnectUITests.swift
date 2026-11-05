import XCTest

/// Recovering a session the app cannot reach, against a live server: an owned session whose
/// host is offline offers Switch Host from the reconnect sheet, and a send into a session bound
/// to no host opens Resume on a Machine and keeps the draft. Screenshots are attachments named
/// `<idiom>-reconnect-<state>`.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and the session ids
/// `OMNIGENT_E2E_OFFLINE_HOST_SESSION` / `OMNIGENT_E2E_UNBOUND_SESSION` (each with the
/// `TEST_RUNNER_` prefix). `OMNIGENT_E2E_SWITCH=1` also performs the switch, which moves that
/// session for good. `OMNIGENT_RECONNECT_SHOTS_DIR` writes each screenshot there as a PNG.
final class PhoneReconnectUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }

  @MainActor
  func testOfflineHostOffersSwitchHost() throws {
    let app = try launch(sessionKey: "OMNIGENT_E2E_OFFLINE_HOST_SESSION")
    // The row's container identifier can stand in for the button's own.
    let row = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'composer-liveness'")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 20), "no reconnect row for the offline host")
    shot("offline-row")
    row.tap()
    let switchHost = app.buttons["reconnect-session-switch-host"]
    XCTAssertTrue(switchHost.waitForExistence(timeout: 5), "the sheet offers no Switch Host")
    shot("reconnect-sheet")
    switchHost.tap()
    let button = app.buttons["switch-host-button"]
    XCTAssertTrue(button.waitForExistence(timeout: 5), "Switch Host did not open")
    // The hosts and the new host's home load after the sheet opens.
    let enabled = NSPredicate(format: "isEnabled == true")
    expectation(for: enabled, evaluatedWith: button)
    waitForExpectations(timeout: 15)
    shot("switch-host-sheet")
    guard environment["OMNIGENT_E2E_SWITCH"] == "1" else { return }
    button.tap()
    XCTAssertTrue(button.waitForNonExistence(timeout: 20), "the switch did not finish")
    XCTAssertTrue(row.waitForNonExistence(timeout: 30), "the session still reads offline")
    shot("switched")
  }

  @MainActor
  func testSendIntoUnboundSessionOpensResume() throws {
    let app = try launch(sessionKey: "OMNIGENT_E2E_UNBOUND_SESSION")
    let input = app.textViews["composer-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 20))
    input.tap()
    input.typeText("Pick up where we left off")
    app.buttons["composer-send"].tap()
    let start = app.buttons["resume-dir-bind-button"]
    XCTAssertTrue(start.waitForExistence(timeout: 5), "the send did not open Resume on a Machine")
    shot("resume-sheet")
    app.navigationBars.buttons["Cancel"].tap()
    XCTAssertTrue(start.waitForNonExistence(timeout: 5))
    XCTAssertEqual(input.value as? String, "Pick up where we left off", "the draft was not kept")
    shot("resume-cancelled")
  }

  // MARK: Helpers

  /// Launches on the live server with the session in `sessionKey` open.
  @MainActor
  private func launch(sessionKey: String) throws -> XCUIApplication {
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let session = environment[sessionKey],
      let host = URL(string: server).flatMap({ url in
        url.host().map { host in url.port.map { "\(host):\($0)" } ?? host }
      })
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and TEST_RUNNER_\(sessionKey).")
    }
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentNoNotificationPrompt", "YES", "-OmnigentOpenURL", "omnigent://\(host)/c/\(session)",
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    return app
  }

  @MainActor
  private func shot(_ state: String) {
    let screenshot = XCUIScreen.main.screenshot()
    let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(idiom)-reconnect-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = environment["OMNIGENT_RECONNECT_SHOTS_DIR"] else { return }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(
      "\(attachment.name ?? state).png")
    do {
      try screenshot.pngRepresentation.write(to: url)
    } catch {
      XCTFail("Could not write \(url.path): \(error)")
    }
  }
}
