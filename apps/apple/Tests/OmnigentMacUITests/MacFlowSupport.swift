import AppKit
import XCTest

/// The steps the Mac user-journey flows share: menus, dialogs, starting a demo session.
///
/// In the demo, demo-notes is read-only, and demo-design and demo-question wait on a request, so
/// they take no message: a flow that sends starts its own session with ``startDemoSession``.
extension MacLiveUITestSupport {
  /// The session's row in the sidebar.
  func row(_ sessionID: String, in app: XCUIApplication) -> XCUIElement {
    element("session-row-\(sessionID)", in: app)
  }

  /// The composer's text view.
  func composer(in app: XCUIApplication) -> XCUIElement {
    element("composer-input", in: app)
  }

  /// The composer's current text.
  func composerText(in app: XCUIApplication) -> String {
    composer(in: app).value as? String ?? ""
  }

  /// The shown session's transcript, whichever session that is.
  func anyTranscript(in app: XCUIApplication) -> XCUIElement {
    elements(prefix: "transcript-", in: app).firstMatch
  }

  /// The hittable element of `query`, once there is one. Closed menus and covered views stay in
  /// the accessibility tree, so existing is not enough; the last one is the frontmost.
  func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 5) -> XCUIElement? {
    var found: XCUIElement?
    _ = waitUntil(timeout: timeout) {
      found = query.allElementsBoundByIndex.last { $0.isHittable }
      return found != nil
    }
    return found
  }

  /// Clicks the open menu's item whose title starts with `title`.
  func clickMenuItem(
    _ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let items = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", title))
    guard let item = hittable(items) else {
      XCTFail("no menu item \(title)\n\(app.debugDescription)", file: file, line: line)
      return
    }
    item.click()
  }

  /// Right-clicks `target` and chooses `title` from its context menu.
  func contextMenu(
    _ target: XCUIElement, choose title: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      target.waitForExistence(timeout: 30), "\(target) is missing", file: file, line: line)
    target.rightClick()
    clickMenuItem(title, in: app, file: file, line: line)
  }

  /// Clicks the button titled `title` of the alert or confirmation in front.
  func clickDialogButton(
    _ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let buttons = app.buttons.matching(
      NSPredicate(format: "title == %@ OR label == %@", title, title))
    guard let button = hittable(buttons, timeout: 10) else {
      XCTFail("no button \(title)\n\(app.debugDescription)", file: file, line: line)
      return
    }
    button.click()
  }

  /// Waits for the sample sessions to load, on the New Tab page's first launch.
  func waitForDemoSessions(in app: XCUIApplication) {
    XCTAssertTrue(
      row("demo-question", in: app).waitForExistence(timeout: 30), "the demo sessions did not load")
  }

  /// Opens the New Session page with Command-N.
  func openNewSession(in app: XCUIApplication) {
    waitForDemoSessions(in: app)
    let page = element("new-session-page", in: app)
    for _ in 0..<3 where !page.exists {
      app.typeKey("n", modifierFlags: .command)
      _ = page.waitForExistence(timeout: 10)
    }
    XCTAssertTrue(page.exists, "Command-N did not open the New Session page")
    XCTAssertTrue(composer(in: app).waitForExistence(timeout: 10), "the page has no composer")
  }

  /// Starts a demo session with `message`, from Command-N to its transcript. A message with "in
  /// detail" gets the long reply, slow enough to work with while it runs.
  func startDemoSession(_ message: String, in app: XCUIApplication) {
    openNewSession(in: app)
    send(message, in: app)
    XCTAssertTrue(
      anyTranscript(in: app).waitForExistence(timeout: 15), "the session did not start")
  }

  /// Starts a demo session and stops its reply, leaving it idle and ready for the next message.
  func startIdleDemoSession(in app: XCUIApplication) {
    startDemoSession("Start \(UUID().uuidString.prefix(6)) in detail", in: app)
    let stop = element("composer-stop", in: app)
    XCTAssertTrue(stop.waitForExistence(timeout: 15), "no reply started")
    click(stop, "Stop")
    XCTAssertTrue(stop.waitForNonExistence(timeout: 15), "the reply did not stop")
  }

  /// Types `message` into the composer and sends it with Command-Return.
  func send(_ message: String, in app: XCUIApplication) {
    click(composer(in: app), "the composer")
    app.typeText(message)
    app.typeKey(.return, modifierFlags: .command)
  }

  /// Waits for `text` in the transcript, once the composer no longer holds it.
  func assertShows(
    _ text: String, in app: XCUIApplication, timeout: TimeInterval = 15,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      waitUntil(timeout: timeout) { !composerText(in: app).contains(text) },
      "the composer kept \(text)", file: file, line: line)
    XCTAssertTrue(
      self.text(containing: text, in: app).waitForExistence(timeout: timeout),
      "\(text) never showed", file: file, line: line)
  }

  /// Waits for the session row's accessibility label to include or leave `text`.
  func assertRow(
    _ sessionID: String, in app: XCUIApplication, contains text: String, _ expected: Bool = true,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let row = row(sessionID, in: app)
    XCTAssertTrue(
      waitUntil(timeout: 15) { row.exists && row.label.contains(text) == expected },
      "\(sessionID)'s row: expected \(expected ? "" : "no ")\(text) in \(row.label)",
      file: file, line: line)
  }

  /// Picks a scope (`All sessions`, `Archived sessions`, ...) from the sidebar's display menu.
  func showDisplayScope(_ scope: String, in app: XCUIApplication) {
    click(element("sidebar-display-menu", in: app), "the display menu")
    clickMenuItem("Display", in: app)
    clickMenuItem(scope, in: app)
  }

  /// Opens the right panel if it is closed.
  func showInspector(in app: XCUIApplication) {
    let inspector = element("session-inspector", in: app)
    if !inspector.exists {
      click(element("toggle-inspector", in: app), "the right-panel toggle")
    }
    XCTAssertTrue(inspector.waitForExistence(timeout: 10), "the right panel did not open")
  }

  /// Quits with Command-Q, which saves windows and tabs, and waits for the app to exit.
  func quit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(
      app.wait(for: .notRunning, timeout: 30), "Command-Q did not quit the app", file: file,
      line: line)
  }

  /// A small text file in a scratch folder, for attaching.
  func writeTextFile(named name: String) throws -> URL {
    let folder = Self.scratchDirectory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    try "Attached by a Mac UI flow.\n".write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
