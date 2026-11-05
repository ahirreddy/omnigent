import XCTest

/// The system navigation bar and the glass composer over a long transcript against a live
/// server, light and dark, in several palettes: scrolled to the middle so text sits under both
/// bars, and with the keyboard open. Screenshots are attachments named
/// `glass-<palette>-<appearance>-<state>`.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_GLASS_SESSION_ID` (with
/// the `TEST_RUNNER_` prefix). `OMNIGENT_GLASS_PALETTES` picks the palettes (`omni,nord` by
/// default).
final class GlassBarsPhoneUITests: XCTestCase {
  @MainActor
  func testTranscriptScrollsUnderTheBars() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_GLASS_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _GLASS_SESSION_ID to run.")
    }
    let palettes = (environment["OMNIGENT_GLASS_PALETTES"] ?? "omni,nord")
      .split(separator: ",").map(String.init)
    addUIInterruptionMonitor(withDescription: "Notifications") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    for palette in palettes {
      for appearance in ["light", "dark"] {
        try capture(server: server, sessionID: sessionID, palette: palette, appearance: appearance)
      }
    }
  }

  @MainActor
  func testDecisionDockAndComposer() throws {
    for appearance in ["light", "dark"] {
      let app = XCUIApplication()
      app.launchArguments += [
        "-OmnigentDemo", "-ApplePersistenceIgnoreState", "YES", "-web-theme", appearance,
      ]
      app.launch()
      XCUIDevice.shared.orientation = .portrait
      try open("demo-design", in: app)
      let card = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH 'decision-dock'")).firstMatch
      XCTAssertTrue(card.waitForExistence(timeout: 15), "the dock did not show")
      sleep(1)
      shot("omni-\(appearance)-decision")
      app.terminate()
    }
  }

  @MainActor
  private func capture(server: String, sessionID: String, palette: String, appearance: String)
    throws
  {
    // Arguments are parsed as property lists; the stored palette is a JSON string, so quote twice.
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
      "-web-theme", appearance, "-omnigent:ui-theme-palette", #""\"\#(palette)\"""#,
      "-OmnigentOpenURL",
      try XCTUnwrap(LiveServerUITestSupport.sessionLink(server: server, sessionID: sessionID)),
    ]
    app.launch()
    defer { app.terminate() }
    XCUIDevice.shared.orientation = .portrait
    let name = "\(palette)-\(appearance)"
    let transcript = app.scrollViews
      .matching(NSPredicate(format: "identifier BEGINSWITH 'transcript-'")).firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 20), "the conversation did not open")
    sleep(2)
    shot("\(name)-bottom")
    // Read from the middle: text under the navigation bar and the composer.
    transcript.swipeDown(velocity: .slow)
    sleep(1)
    shot("\(name)-scrolled")
    let input = app.textViews["composer-input"].firstMatch
    if input.waitForExistence(timeout: 5) {
      input.tap()
      _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
      sleep(1)
      shot("\(name)-keyboard")
    }
  }

  /// Opens a demo session from the sidebar, going back until its row shows.
  @MainActor
  private func open(_ sessionID: String, in app: XCUIApplication) throws {
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"]
    for _ in 0..<3 where !row.waitForExistence(timeout: 8) {
      let back = app.navigationBars.buttons["BackButton"]
      guard back.exists else { break }
      back.tap()
    }
    XCTAssertTrue(row.exists, "no row for \(sessionID)")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
  }

  @MainActor
  private func shot(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "glass-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
