import UIKit
import XCTest

/// Browser tabs and workspace file actions on iPhone and iPad against a live server: New Tab
/// offers Browser and the page loads, a transcript link opens in a browser tab when Settings asks
/// for in-app links, and a workspace file opens in Quick Look and the share sheet.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL`, `OMNIGENT_LINK_SESSION_ID` (a
/// session whose transcript has a web link) and `OMNIGENT_FILES_SESSION_ID` (a session whose
/// workspace has `notes.md` and `notes.pdf`), with the `TEST_RUNNER_` prefix. Set
/// `TEST_RUNNER_BROWSER_SHOTS_DIR` to also write each state as `<device>-<state>.png` there.
final class BrowserTabsUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  @MainActor
  func testNewTabOpensABrowserThatLoadsAPage() throws {
    let app = try launch()
    try open(try setting("OMNIGENT_LINK_SESSION_ID"), in: app)
    if isPhone {
      tap(app.buttons["tab-switcher"], "the tab switcher")
      tap(app.buttons["tab-overview-new"], "New Tab in the overview")
    } else {
      tap(app.buttons["tab-new"], "New Tab in the strip")
    }
    tap(app.descendants(matching: .any)["newtab-browser"], "Browser on the new-tab page")
    let omnibox = app.textFields["browser.omnibox"]
    XCTAssertTrue(omnibox.waitForExistence(timeout: 10), "the browser tab did not open")
    sleep(3)
    if isPhone { assertOneAddressRow(in: app, omnibox: omnibox) }
    try shot("browser-server-page")

    omnibox.tap()
    omnibox.typeText("example.com\n")
    XCTAssertTrue(
      app.webViews.staticTexts["Example Domain"].waitForExistence(timeout: 20),
      "example.com did not load")
    XCTAssertTrue(app.buttons["browser.back"].isEnabled, "Back stays off after a navigation")
    if isPhone {
      XCTAssertTrue(app.descendants(matching: .any)["browser.bottomBar"].exists)
    }
    try shot("browser-example")
    tap(app.buttons["browser.share"], "Share")
    XCTAssertTrue(
      app.otherElements["ActivityListView"].waitForExistence(timeout: 10)
        || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5),
      "the share sheet did not open")
    sleep(1)
    try shot("browser-share")
  }

  @MainActor
  func testTranscriptLinkOpensInABrowserTab() throws {
    let app = try launch(extra: ["-omnigent:open-links-in-app", "YES"])
    try open(try setting("OMNIGENT_LINK_SESSION_ID"), in: app)
    let link = app.links["link"].firstMatch
    XCTAssertTrue(link.waitForExistence(timeout: 20), "the transcript shows no link")
    link.tap()
    let omnibox = app.textFields["browser.omnibox"]
    XCTAssertTrue(omnibox.waitForExistence(timeout: 10), "the link did not open a browser tab")
    XCTAssertTrue(
      app.webViews.staticTexts["Example Domain"].waitForExistence(timeout: 20),
      "the linked page did not load")
    XCTAssertTrue((omnibox.value as? String ?? "").contains("example.com"))
    try shot("transcript-link")
  }

  @MainActor
  func testWorkspaceFileOpensInQuickLookAndShare() throws {
    let app = try launch()
    try open(try setting("OMNIGENT_FILES_SESSION_ID"), in: app)
    tap(app.buttons["toggle-inspector"], "the right-panel toggle")
    let pdf = app.staticTexts["notes.pdf"].firstMatch
    XCTAssertTrue(pdf.waitForExistence(timeout: 20), "the files panel shows no notes.pdf")
    try shot("files-panel")

    pdf.press(forDuration: 1.2)
    tap(app.buttons["Quick Look"], "Quick Look in the file's menu")
    let preview = app.navigationBars.matching(
      NSPredicate(format: "identifier CONTAINS 'QL' OR identifier CONTAINS 'notes'")
    ).firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 15), "Quick Look did not open")
    sleep(2)
    try shot("files-quicklook")
    tap(app.buttons["Done"].firstMatch, "Done in Quick Look")

    let markdown = app.staticTexts["notes.md"].firstMatch
    XCTAssertTrue(markdown.waitForExistence(timeout: 10))
    markdown.press(forDuration: 1.2)
    tap(app.buttons["Share\u{2026}"], "Share in the file's menu")
    XCTAssertTrue(
      app.otherElements["ActivityListView"].waitForExistence(timeout: 15)
        || app.navigationBars["UIActivityContentView"].waitForExistence(timeout: 5),
      "the share sheet did not open")
    sleep(1)
    try shot("files-share")
  }

  // MARK: Helpers

  /// On iPhone the address pill shares one row with Sessions and the tab overview, in place of
  /// the app's navigation bar.
  @MainActor
  private func assertOneAddressRow(in app: XCUIApplication, omnibox: XCUIElement) {
    let row = app.descendants(matching: .any)["browser.addressBar"]
    let sessions = row.buttons["browser.sessions"]
    let tabs = row.buttons["tab-switcher"]
    XCTAssertTrue(sessions.exists, "the address row has no Sessions button")
    XCTAssertTrue(tabs.exists, "the address row has no tab overview button")
    XCTAssertEqual(sessions.frame.midY, omnibox.frame.midY, accuracy: 4)
    XCTAssertEqual(tabs.frame.midY, omnibox.frame.midY, accuracy: 4)
    let navigationBack = app.navigationBars.buttons["BackButton"]
    XCTAssertFalse(navigationBack.exists && navigationBack.isHittable, "the navigation bar shows")
  }

  @MainActor
  private func setting(_ name: String) throws -> String {
    guard let value = environment[name] else {
      throw XCTSkip("Set TEST_RUNNER_\(name) to run.")
    }
    return value
  }

  /// The app connected to the live server, with no restored tabs.
  @MainActor
  private func launch(extra: [String] = []) throws -> XCUIApplication {
    let server = try setting("OMNIGENT_E2E_SERVER_URL")
    let app = XCUIApplication()
    app.launchArguments +=
      ["-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES"] + extra
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    return app
  }

  /// Opens a session from the sidebar, going back until its row shows.
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
    guard let directory = environment["BROWSER_SHOTS_DIR"] else { return }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(state).png"))
  }
}
