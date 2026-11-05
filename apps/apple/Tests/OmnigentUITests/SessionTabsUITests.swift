import UIKit
import XCTest

/// Tabs belong to a session, on iPhone and iPad against the offline demo server: a browser tab
/// opened in one session leaves the strip (or the iPhone tab overview) when another session
/// shows, and comes back selected when the first session shows again.
///
/// Set `TEST_RUNNER_SESSION_TABS_SHOTS_DIR` to also write each state as `<device>-<state>.png`.
final class SessionTabsUITests: XCTestCase {
  private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  @MainActor
  func testSwitchingSessionsSwapsTheirTabs() throws {
    let app = launch()
    try open("demo-design", in: app)
    openBrowserTab(in: app)
    // The browser's address field, by its placeholder: the page's identifier hides the field's.
    let browser = app.textFields
      .matching(NSPredicate(format: "placeholderValue == 'Search or enter address'")).firstMatch
    XCTAssertTrue(browser.waitForExistence(timeout: 10), "the browser tab did not open")
    XCTAssertEqual(otherTabs(in: app), 1, "the first session has no browser tab")
    try shot("first-session-browser")

    try open("demo-question", in: app)
    XCTAssertFalse(browser.waitForExistence(timeout: 2), "the browser stayed on screen")
    XCTAssertEqual(otherTabs(in: app), 0, "the other session shows the first one's tab")
    try shot("second-session")

    try open("demo-design", in: app)
    XCTAssertTrue(browser.waitForExistence(timeout: 10), "coming back lost the browser tab")
    XCTAssertEqual(otherTabs(in: app), 1, "the first session's tabs did not come back")
    try shot("first-session-again")
  }

  // MARK: Helpers

  /// A clean demo launch: no saved server, no restored state, and tabs saved apart.
  @MainActor
  private func launch() -> XCUIApplication {
    let tabs = FileManager.default.temporaryDirectory
      .appendingPathComponent("session-tabs-\(UUID().uuidString)")
    let app = XCUIApplication()
    app.launchArguments += [
      "-OmnigentDemo", "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    return app
  }

  /// Opens New Tab in the shown session and picks Browser.
  @MainActor
  private func openBrowserTab(in app: XCUIApplication) {
    if isPhone {
      tap(app.buttons["tab-switcher"], "the tab switcher")
      tap(app.buttons["tab-overview-new"], "New Tab in the overview")
    } else {
      tap(app.buttons["tab-new"], "New Tab in the strip")
    }
    tap(app.descendants(matching: .any)["newtab-browser"], "Browser on the new-tab page")
  }

  /// How many tabs besides its chat the shown session has: browser tabs in the strip on iPad,
  /// rows in the tab overview on iPhone (opened and closed again).
  @MainActor
  private func otherTabs(in app: XCUIApplication) -> Int {
    guard isPhone else {
      return app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-browser-'")).count
    }
    tap(app.buttons["tab-switcher"], "the tab switcher")
    let rows = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-overview-row-'"))
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5), "the tab overview is empty")
    let count = rows.count - 1
    tap(app.buttons["tab-overview-done"], "Done in the tab overview")
    return count
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
    sleep(2)
  }

  @MainActor
  private func tap(_ element: XCUIElement, _ name: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), "\(name) is missing")
    element.tap()
  }

  @MainActor
  private func shot(_ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let device = isPhone ? "iphone" : "ipad"
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(device)-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["SESSION_TABS_SHOTS_DIR"] else { return }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(state).png"))
  }
}
