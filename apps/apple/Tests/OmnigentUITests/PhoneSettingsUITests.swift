import XCTest

/// The iPhone and iPad Settings screen against a live server: the server menu's Settings opens
/// it, every page and offered server pane pushes and shows its form, and the palette's Go to
/// Settings and Usage open too. Screenshots are attachments named `<idiom>-settings-<page>`.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` (with the `TEST_RUNNER_` prefix).
/// `OMNIGENT_SETTINGS_SHOTS_DIR` also writes each screenshot there as a PNG.
final class PhoneSettingsUITests: XCTestCase {
  /// The rows the screen can list, app pages first, by accessibility identifier.
  private static let rows =
    ["general", "appearance", "notifications", "terminal"].map { "settings-page-\($0)" }
    + [
      "account", "harnesses", "customAgents", "mcp", "integrations", "git", "importSessions",
      "members", "policies", "sharing", "archived",
    ].map { "server-settings-pane-\($0)" }

  @MainActor
  func testEveryPageOpens() throws {
    guard let server = ProcessInfo.processInfo.environment["OMNIGENT_E2E_SERVER_URL"] else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL to run.")
    }
    addUIInterruptionMonitor(withDescription: "Notifications") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    // Notification permission is asked once per install, after sign-in.
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow"]
    if allow.waitForExistence(timeout: 15) { allow.tap() }
    XCUIDevice.shared.orientation = .portrait
    try openFromServerMenu(app)
    shot("root")

    var opened: [String] = []
    for row in Self.rows {
      guard let cell = find(row, in: app) else { continue }
      cell.tap()
      let back = app.navigationBars.buttons.element(boundBy: 0)
      XCTAssertTrue(back.waitForExistence(timeout: 10), "\(row) did not push")
      sleep(2)
      let name = row.components(separatedBy: "-").last ?? row
      shot(name)
      back.tap()
      opened.append(name)
    }
    XCTAssertTrue(opened.contains("general") && opened.contains("harnesses"), "\(opened)")

    app.buttons["settings-done"].tap()
    XCTAssertTrue(screen(app).waitForNonExistence(timeout: 10))
    try paletteOpens("Settings", in: app)
    XCTAssertTrue(screen(app).waitForExistence(timeout: 10), "Go to Settings did not open")
    shot("palette")
    app.buttons["settings-done"].tap()
    XCTAssertTrue(screen(app).waitForNonExistence(timeout: 10))
    if (try? paletteOpens("Usage", in: app)) != nil {
      sleep(3)
      shot("usage")
      app.swipeUp()
      shot("usage-sessions")
    }
  }

  @MainActor
  private func screen(_ app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)["settings-screen"]
  }

  /// Opens Settings from the sidebar's server menu, going back to the sidebar first.
  @MainActor
  private func openFromServerMenu(_ app: XCUIApplication) throws {
    let switcher = app.buttons["server-switcher"]
    for _ in 0..<3 where !switcher.waitForExistence(timeout: 15) {
      let back = app.navigationBars.buttons.firstMatch
      if back.exists { back.tap() }
    }
    XCTAssertTrue(switcher.exists, "No server menu")
    switcher.tap()
    let settings = app.buttons["sidebar-settings-screen"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5), "No Settings item")
    settings.tap()
    XCTAssertTrue(screen(app).waitForExistence(timeout: 10), "Settings did not open")
  }

  /// Picks the palette entry whose title contains `title`.
  @MainActor
  private func paletteOpens(_ title: String, in app: XCUIApplication) throws {
    let search = app.buttons["sidebar-search"]
    XCTAssertTrue(search.waitForExistence(timeout: 10), "No palette button")
    search.tap()
    app.typeText(title)
    let entry = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    guard entry.waitForExistence(timeout: 5) else {
      app.typeText("\u{1B}")
      throw XCTSkip("The palette has no \(title)")
    }
    entry.tap()
  }

  /// The row `identifier`, scrolling the list down for it; `nil` when the server doesn't offer it.
  /// Rows are visited top to bottom, so it never scrolls back up: on iPad a swipe down on the
  /// short list would dismiss the sheet.
  @MainActor
  private func find(_ identifier: String, in app: XCUIApplication) -> XCUIElement? {
    let cell = app.descendants(matching: .any)[identifier]
    // The Settings list, not the sidebar behind the iPad sheet.
    let list = screen(app).collectionViews.firstMatch
    for _ in 0..<3 {
      if cell.exists, cell.isHittable { return cell }
      list.swipeUp()
    }
    return cell.exists && cell.isHittable ? cell : nil
  }

  @MainActor
  private func shot(_ name: String) {
    let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(idiom)-settings-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_SETTINGS_SHOTS_DIR"]
    else { return }
    do {
      try screenshot.pngRepresentation.write(
        to: URL(fileURLWithPath: directory).appendingPathComponent(
          "\(idiom)-settings-\(name).png"))
    } catch {
      XCTFail("Could not write \(name): \(error)")
    }
  }
}
