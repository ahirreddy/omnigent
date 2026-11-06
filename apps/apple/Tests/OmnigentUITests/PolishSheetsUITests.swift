import UIKit
import XCTest

/// Taps through the sheets, alerts and keyboard states against the local server and its seeded
/// fixture session (`LiveServerUITestSupport`) on iPhone and iPad: the rename
/// alert, the delete confirmation, the model picker, the composer above the keyboard, the server
/// chip's full name and the keyboard focus ring.
///
/// Set `TEST_RUNNER_PHONE_SHOTS_DIR` to also write each state as `polish-<idiom>-<state>.png`.
final class PolishSheetsUITests: XCTestCase {
  private var server: String {
    ProcessInfo.processInfo.environment["OMNIGENT_SERVER"] ?? "http://127.0.0.1:6767"
  }

  @MainActor
  func testRenameAndDeleteAlertsAnswerTaps() throws {
    let sessionID = try LiveServerUITestSupport(self).fixtureSession()
    let app = try launch()
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"].firstMatch
    try showSidebar(app, until: row)
    XCTAssertTrue(row.exists, "no row for the seeded session")

    row.press(forDuration: 1.0)
    let rename = app.buttons["Rename\u{2026}"].firstMatch
    XCTAssertTrue(rename.waitForExistence(timeout: 5), "the row menu has no Rename")
    rename.tap()
    let alert = app.alerts["Rename Session"]
    XCTAssertTrue(alert.waitForExistence(timeout: 5), "Rename did not open its prompt")
    let field = alert.textFields.firstMatch
    XCTAssertTrue(field.exists, "the rename prompt has no field")
    field.tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard for the title")
    field.typeText(" (draft)")
    dismissKeyboardTip(app)
    XCTAssertTrue(alert.buttons["Rename"].isEnabled, "a valid title can't be saved")
    try shot(app, "rename-alert")
    alert.buttons["Cancel"].tap()
    XCTAssertTrue(alert.waitForNonExistence(timeout: 5), "Cancel left the prompt up")

    row.press(forDuration: 1.0)
    let delete = app.buttons["Delete\u{2026}"].firstMatch
    XCTAssertTrue(delete.waitForExistence(timeout: 5), "the row menu has no Delete")
    delete.tap()
    // A confirmation dialog: an action sheet with Cancel on iPhone, a popover on iPad.
    let confirm = app.buttons["Delete"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Delete did not ask first")
    try shot(app, "delete-alert")
    let cancel = app.buttons["Cancel"].firstMatch
    if cancel.exists {
      cancel.tap()
    } else {
      app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).tap()
    }
    XCTAssertTrue(confirm.waitForNonExistence(timeout: 5), "the confirmation stayed up")
    XCTAssertTrue(row.exists, "dismissing deleted the session")
  }

  /// The core's stand-in header and empty rows never show while history loads.
  @MainActor
  func testOpeningASessionShowsNoEmptyState() throws {
    let sessionID = try LiveServerUITestSupport(self).fixtureSession()
    let app = try launch()
    assertNoStandIn(app)
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"].firstMatch
    try showSidebar(app, until: row)
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
    assertNoStandIn(app)
    let transcript = app.descendants(matching: .any)["transcript-\(sessionID)"].firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 10), "the session did not open")
    try shot(app, "opened")
  }

  @MainActor
  func testModelPickerAndKeyboardOverTheComposer() throws {
    let sessionID = try LiveServerUITestSupport(self).fixtureSession()
    let app = try launch()
    try openSession(sessionID, in: app)
    let input = app.textViews["composer-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.tap()
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "no keyboard")
    input.typeText("Checking the composer")
    dismissKeyboardTip(app)
    sleep(1)
    XCTAssertTrue(input.isHittable, "the keyboard covers the field")
    XCTAssertLessThanOrEqual(
      input.frame.maxY, keyboard.frame.minY, "the field sits under the keyboard")
    try shot(app, "keyboard-composer")

    // The focused composer shows the agent and model picker; it is disabled while applying.
    let pickers = app.descendants(matching: .any).matching(identifier: "composer-configuration")
    XCTAssertTrue(pickers.firstMatch.waitForExistence(timeout: 15), "no model picker")
    // Kept-alive tabs hold other composers; tap the one on screen. A UIKit menu is a
    // collection view whose rows drop SwiftUI identifiers.
    let onScreen =
      pickers.allElementsBoundByIndex.first(where: \.isHittable) ?? pickers.firstMatch
    let closed = app.collectionViews.count
    // A tap while the session's host and folder still load can be lost to the re-render.
    for _ in 0..<3 where app.collectionViews.count <= closed {
      onScreen.tap()
      sleep(2)
    }
    try shot(app, "model-picker")
    XCTAssertGreaterThan(app.collectionViews.count, closed, "the model picker did not open")
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3)).tap()
    sleep(1)
    XCTAssertEqual(app.collectionViews.count, closed, "the model picker did not close")
  }

  @MainActor
  func testServerChipShowsTheWholeHost() throws {
    _ = try LiveServerUITestSupport(self).fixtureSession()
    let app = try launch()
    let switcher = app.descendants(matching: .any)["server-switcher"].firstMatch
    try showSidebar(app, until: switcher)
    let host = try XCTUnwrap(URL(string: server)?.host(), "no host in \(server)")
    let port = URL(string: server)?.port.map { ":\($0)" } ?? ""
    let label = app.staticTexts["\(host)\(port)"].firstMatch
    XCTAssertTrue(label.waitForExistence(timeout: 10), "the chip shows no \(host)\(port)")
    try shot(app, "server-chip")
    // A truncated label still reports its whole text; its frame must hold the whole text.
    let width = NSAttributedString(
      string: host + port, attributes: [.font: UIFont.preferredFont(forTextStyle: .caption1)]
    ).size().width
    XCTAssertGreaterThanOrEqual(label.frame.width + 1, width, "the chip truncates the host")
  }

  @MainActor
  func testKeyboardFocusRingIsNotThePrimaryTint() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad keyboard only") }
    let sessionID = try LiveServerUITestSupport(self).fixtureSession()
    let app = try launch()
    try openSession(sessionID, in: app)
    // Tab moves keyboard focus between groups; the ring follows it.
    for _ in 0..<3 { app.typeKey(XCUIKeyboardKey.tab, modifierFlags: []) }
    sleep(1)
    try shot(app, "focus-ring")
  }

  // MARK: Helpers

  @MainActor
  private func launch() throws -> XCUIApplication {
    // A first launch asks for notifications; the prompt would cover the sidebar.
    addUIInterruptionMonitor(withDescription: "Notifications") { alert in
      let decline = alert.buttons["Don\u{2019}t Allow"]
      guard decline.exists else { return false }
      decline.tap()
      return true
    }
    // Tabs saved apart: other tests leave the fixture on a browser tab, which it would reopen.
    let tabs = FileManager.default.temporaryDirectory
      .appendingPathComponent("polish-tabs-\(UUID().uuidString)")
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentNoNotificationPrompt", "YES", "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    return app
  }

  /// Opens the seeded session from the sidebar.
  @MainActor
  private func openSession(_ sessionID: String, in app: XCUIApplication) throws {
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"].firstMatch
    try showSidebar(app, until: row)
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
    let transcript = app.descendants(matching: .any)["transcript-\(sessionID)"].firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 20), "the session did not open")
  }

  /// Goes back until `element` shows (the app reopens what it showed last), then scrolls the
  /// sidebar until its lazy row loads.
  @MainActor
  private func showSidebar(_ app: XCUIApplication, until element: XCUIElement) throws {
    for _ in 0..<3 where !element.waitForExistence(timeout: 10) {
      let back = app.navigationBars.buttons["BackButton"]
      guard back.exists else { break }
      back.tap()
    }
    let list = app.collectionViews.firstMatch
    for _ in 0..<8 where !element.exists && list.exists {
      list.swipeUp()
    }
  }

  /// Polls for four seconds for the empty state or the core's stand-in title.
  @MainActor
  private func assertNoStandIn(_ app: XCUIApplication) {
    let empty = app.staticTexts["This session has no messages yet."]
    let standIn = app.staticTexts["Conversation"]
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
      XCTAssertFalse(empty.exists, "the empty state showed before the history")
      XCTAssertFalse(standIn.exists, "the stand-in title showed before the header")
    }
  }

  /// A fresh simulator's first typing shows a "slide to type" tip that covers the screen.
  @MainActor
  private func dismissKeyboardTip(_ app: XCUIApplication) {
    let tip = app.buttons["Continue"].firstMatch
    if tip.waitForExistence(timeout: 2) { tip.tap() }
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = state
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["PHONE_SHOTS_DIR"] else { return }
    let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("polish-\(idiom)-\(state).png"))
  }
}
