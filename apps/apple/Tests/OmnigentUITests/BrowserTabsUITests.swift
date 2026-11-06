import UIKit
import XCTest

/// Browser tabs and workspace file actions on iPhone and iPad against a live server: New Tab
/// offers Browser and the page loads, a transcript link opens in a browser tab when Settings asks
/// for in-app links, and a workspace file opens in Quick Look and the share sheet.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL`, `OMNIGENT_LINK_SESSION_ID` (a
/// session whose transcript links "Example Domain" to example.com) and
/// `OMNIGENT_FILES_SESSION_ID` (a session whose workspace has `notes.md` and `notes.pdf`), with
/// the `TEST_RUNNER_` prefix; `just apple-uitest-ios` passes its seeded fixture for both. Set
/// `TEST_RUNNER_BROWSER_SHOTS_DIR` to also write each state as `<device>-<state>.png` there.
final class BrowserTabsUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  @MainActor
  func testNewTabOpensABrowserThatLoadsAPage() throws {
    let app = try launch(opening: try setting("OMNIGENT_LINK_SESSION_ID"))
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

    // The server's page can take the keyboard as it finishes loading.
    LiveServerUITestSupport(self).type("example.com\n", into: omnibox)
    XCTAssertTrue(
      examplePage(app).waitForExistence(timeout: 20),
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
    let app = try launch(
      opening: try setting("OMNIGENT_LINK_SESSION_ID"),
      extra: ["-omnigent:open-links-in-app", "YES"])
    let link = app.links["Example Domain"].firstMatch
    XCTAssertTrue(link.waitForExistence(timeout: 20), "the transcript shows no link")
    link.tap()
    let omnibox = app.textFields["browser.omnibox"]
    XCTAssertTrue(omnibox.waitForExistence(timeout: 10), "the link did not open a browser tab")
    XCTAssertTrue(
      examplePage(app).waitForExistence(timeout: 20),
      "the linked page did not load")
    XCTAssertTrue((omnibox.value as? String ?? "").contains("example.com"))
    try shot("transcript-link")
  }

  @MainActor
  func testWorkspaceFileOpensInQuickLookAndShare() throws {
    let app = try launch(opening: try setting("OMNIGENT_FILES_SESSION_ID"))
    tap(app.buttons["toggle-inspector"], "the right-panel toggle")
    let pdf = app.descendants(matching: .any)["notes.pdf"].firstMatch
    XCTAssertTrue(pdf.waitForExistence(timeout: 20), "the files panel shows no notes.pdf")
    try shot("files-panel")

    pdf.press(forDuration: 1.2)
    tap(app.buttons["Quick Look"], "Quick Look in the file's menu")
    let preview = app.otherElements["QLPreviewControllerView"]
    XCTAssertTrue(preview.waitForExistence(timeout: 30), "Quick Look did not open")
    sleep(2)
    try shot("files-quicklook")
    // iOS 26's Quick Look closes with an X, not Done.
    tap(app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"], "Close in Quick Look")

    let markdown = app.descendants(matching: .any)["notes.md"].firstMatch
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

  /// Text of example.com's page, whose wording changes ("Example Domain", "examples").
  @MainActor
  private func examplePage(_ app: XCUIApplication) -> XCUIElement {
    app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'example'"))
      .firstMatch
  }

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

  /// The app connected to the live server with no restored tabs, showing `sessionID`.
  @MainActor
  private func launch(opening sessionID: String, extra: [String] = []) throws -> XCUIApplication {
    let server = try setting("OMNIGENT_E2E_SERVER_URL")
    let link = try XCTUnwrap(
      LiveServerUITestSupport.sessionLink(server: server, sessionID: sessionID))
    let app = XCUIApplication()
    app.launchArguments +=
      ["-omnigent.lastServer", server, "-OmnigentOpenURL", link]
      + LiveServerUITestSupport.freshStateArguments + extra
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    XCTAssertTrue(
      app.descendants(matching: .any)["transcript-\(sessionID)"].waitForExistence(timeout: 30),
      "the session did not open")
    return app
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
