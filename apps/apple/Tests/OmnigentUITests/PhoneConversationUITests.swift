import UIKit
import XCTest

/// iPhone conversation geometry and composer behavior against the offline demo server, in chat
/// and CLI styles: the demo opens to sessions on a clean launch, a short transcript starts under
/// the navigation bar, a read-only session shows no field, the first tap on the composer focuses
/// it, and the new-session composer sits on the keyboard.
///
/// Set `TEST_RUNNER_PHONE_SHOTS_DIR` to also write each state as `<prefix>-<style>-<state>.png`
/// there (prefix from `TEST_RUNNER_PHONE_SHOTS_PREFIX`).
final class PhoneConversationUITests: XCTestCase {
  /// The most a short transcript's first message may sit below the navigation bar.
  private let maximumTopGap: CGFloat = 48
  /// The navigation bar's height with an inline title and subtitle.
  private let maximumBarHeight: CGFloat = 80
  /// The most the new-session composer may float above the keyboard's frame, which starts below
  /// the 44 pt predictive bar: the bar plus at most 16 pt of clearance.
  private let maximumKeyboardGap: CGFloat = 60

  @MainActor
  func testDemoOpensSessionsOnCleanLaunch() throws {
    let app = launch(style: "chat")
    let newSession = app.descendants(matching: .any)["sidebar-new-session"].firstMatch
    try showSidebar(app, until: newSession)
    XCTAssertTrue(newSession.exists, "the demo did not open to sessions")
    XCTAssertFalse(app.buttons["auth.connect"].exists, "the demo showed the Connect screen")
  }

  @MainActor
  func testShortTranscriptStartsUnderTheBarAndReadOnlyHasNoField() throws {
    try skipUnlessPhone()
    for style in ["chat", "cli"] {
      let app = launch(style: style)
      try open("demo-notes", in: app)
      let message = app.descendants(matching: .any)["message-notes-request"]
      guard message.waitForExistence(timeout: 10) else {
        try shot(app, style, "read-only-not-opened")
        XCTFail("\(style): the read-only session did not open")
        continue
      }
      // Let the first layout and the initial scroll settle.
      sleep(1)
      let bar = app.navigationBars.firstMatch
      // An inline title: no large-title band between the bar's buttons and the transcript.
      XCTAssertLessThanOrEqual(bar.frame.height, maximumBarHeight, "\(style): a band under the bar")
      let gap = message.frame.minY - bar.frame.maxY
      XCTAssertLessThanOrEqual(gap, maximumTopGap, "\(style): \(gap) pt between bar and message")
      XCTAssertFalse(
        app.textViews["composer-input"].exists, "\(style): a read-only session shows a field")
      XCTAssertTrue(app.descendants(matching: .any)["composer-read-only"].exists)
      try shot(app, style, "read-only-short")
    }
  }

  @MainActor
  func testFirstComposerTapFocuses() throws {
    try skipUnlessPhone()
    for style in ["chat", "cli"] {
      let app = launch(style: style)
      try open("demo-question", in: app)
      let input = app.textViews["composer-input"]
      XCTAssertTrue(input.waitForExistence(timeout: 10))
      input.tap()
      XCTAssertTrue(
        app.keyboards.firstMatch.waitForExistence(timeout: 3), "\(style): the first tap was refused"
      )
      try shot(app, style, "first-tap")
    }
  }

  @MainActor
  func testNewSessionComposerSitsOnTheKeyboard() throws {
    try skipUnlessPhone()
    for style in ["chat", "cli"] {
      let app = launch(style: style)
      let newSession = app.descendants(matching: .any)["sidebar-new-session"].firstMatch
      try showSidebar(app, until: newSession)
      newSession.tap()
      let input = app.textViews["composer-input"]
      XCTAssertTrue(input.waitForExistence(timeout: 10))
      try shot(app, style, "new-session")
      input.tap()
      let keyboard = app.keyboards.firstMatch
      XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
      input.typeText("Summarize the open questions")
      sleep(1)
      let composer = app.descendants(matching: .any)["composer"].firstMatch
      let gap = keyboard.frame.minY - composer.frame.maxY
      XCTAssertLessThanOrEqual(gap, maximumKeyboardGap, "\(style): \(gap) pt above the keyboard")
      try shot(app, style, "new-session-typing")
    }
  }

  @MainActor
  func testFirstExchangeStartsUnderTheBar() throws {
    try skipUnlessPhone()
    for style in ["chat", "cli"] {
      let app = launch(style: style)
      let newSession = app.descendants(matching: .any)["sidebar-new-session"].firstMatch
      try showSidebar(app, until: newSession)
      newSession.tap()
      let input = app.textViews["composer-input"]
      XCTAssertTrue(input.waitForExistence(timeout: 10))
      input.tap()
      input.typeText("Summarize the open questions")
      app.buttons["composer-send"].tap()
      let first = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH 'message-'")).firstMatch
      XCTAssertTrue(first.waitForExistence(timeout: 15))
      _ = app.buttons["composer-stop"].waitForNonExistence(timeout: 60)
      // Hide the keyboard so the whole transcript shows.
      app.scrollViews.matching(NSPredicate(format: "identifier BEGINSWITH 'transcript-'"))
        .firstMatch.swipeDown()
      sleep(1)
      let gap = first.frame.minY - app.navigationBars.firstMatch.frame.maxY
      XCTAssertLessThanOrEqual(gap, maximumTopGap, "\(style): \(gap) pt between bar and message")
      try shot(app, style, "first-exchange")
    }
  }

  // MARK: Helpers

  /// A clean demo launch: no saved server, no restored state.
  @MainActor
  private func launch(style: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-OmnigentDemo", "-ApplePersistenceIgnoreState", "YES",
      "-omnigent:transcript-style", style,
    ]
    // `TEST_RUNNER_PHONE_THEME` (light or dark) sets the app's appearance.
    if let theme = ProcessInfo.processInfo.environment["PHONE_THEME"] {
      app.launchArguments += ["-web-theme", theme]
    }
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    return app
  }

  /// Opens a demo session from the sidebar.
  @MainActor
  private func open(_ sessionID: String, in app: XCUIApplication) throws {
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"]
    try showSidebar(app, until: row)
    XCTAssertTrue(row.exists, "no row for \(sessionID)")
    // Tap near the row's top: on a small phone the floating search field covers its lower half.
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
  }

  /// Goes back until `element` shows: the app reopens the tab it showed last.
  @MainActor
  private func showSidebar(_ app: XCUIApplication, until element: XCUIElement) throws {
    for _ in 0..<3 where !element.waitForExistence(timeout: 8) {
      let back = app.navigationBars.buttons["BackButton"]
      guard back.exists else {
        try shot(app, "navigation", "no-back-button")
        return
      }
      back.tap()
    }
  }

  @MainActor
  private func skipUnlessPhone() throws {
    guard UIDevice.current.userInterfaceIdiom == .phone else {
      throw XCTSkip("iPhone layout only")
    }
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ style: String, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(style)-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["PHONE_SHOTS_DIR"] else { return }
    let prefix = environment["PHONE_SHOTS_PREFIX"] ?? "phone"
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(style)-\(state).png"))
  }
}
