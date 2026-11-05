import XCTest

final class OmnigentUITests: XCTestCase {
  @MainActor
  func testLaunchShowsConnectForm() {
    let app = XCUIApplication()
    // No server to reconnect to, whatever the simulator last used.
    app.launchArguments = ["-omnigent.lastServer", "", "-ApplePersistenceIgnoreState", "YES"]
    app.launch()

    XCTAssertTrue(app.buttons["auth.connect"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["auth.server-url"].exists)
  }

  /// The touch composer against the offline demo server: a new session, typing, running with
  /// Stop in reach (with and without a draft), idle, and a pending request docked. Set
  /// `TEST_RUNNER_COMPOSER_SHOTS_DIR` to also write each state as `<prefix>-<state>.png` there
  /// (prefix from `TEST_RUNNER_COMPOSER_SHOTS_PREFIX`).
  @MainActor
  func testComposerStatesOnTouch() throws {
    let app = XCUIApplication()
    app.launchArguments +=
      ["-OmnigentDemo", "-omnigent.lastServer", "http://127.0.0.1:6767"]
      + LiveServerUITestSupport.freshStateArguments
    app.launch()

    let any = app.descendants(matching: .any)
    let newSession = any.matching(identifier: "sidebar-new-session").firstMatch
    showSidebar(app, until: newSession)
    XCTAssertTrue(newSession.waitForExistence(timeout: 15))
    newSession.tap()
    let input = app.textViews["composer-input"].firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    try shot(app, "new")

    LiveServerUITestSupport(self).type("Summarize the open questions", into: input)
    try shot(app, "typing")
    app.buttons["composer-send"].tap()

    // Running: Stop stays in reach (the placeholder's wording is covered by unit tests).
    let stop = app.buttons["composer-stop"]
    if stop.waitForExistence(timeout: 10) {
      try shot(app, "running")
      let running = app.textViews["composer-input"].firstMatch
      LiveServerUITestSupport(self).type("Also list the risks", into: running)
      try shot(app, "running-draft")
      // The demo reply may finish while typing; Send joins Stop only while it runs.
      if stop.exists { XCTAssertTrue(app.buttons["composer-send"].exists) }
      XCTAssertTrue(stop.waitForNonExistence(timeout: 60))
    }
    try shot(app, "idle")

    let design = any.matching(identifier: "session-row-demo-design").firstMatch
    showSidebar(app, until: design)
    XCTAssertTrue(design.waitForExistence(timeout: 10))
    design.tap()
    XCTAssertTrue(app.textViews["composer-input"].firstMatch.waitForExistence(timeout: 10))
    try shot(app, "pending")
  }

  /// Goes back until `element` shows (a restored window may open on a session).
  @MainActor
  private func showSidebar(_ app: XCUIApplication, until element: XCUIElement) {
    for _ in 0..<3 where !element.waitForExistence(timeout: 5) {
      let back = app.navigationBars.buttons.firstMatch
      guard back.exists else { return }
      back.tap()
    }
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = state
    attachment.lifetime = .keepAlways
    add(attachment)
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["COMPOSER_SHOTS_DIR"] else { return }
    let prefix = environment["COMPOSER_SHOTS_PREFIX"] ?? "composer"
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(state).png"))
  }
}
