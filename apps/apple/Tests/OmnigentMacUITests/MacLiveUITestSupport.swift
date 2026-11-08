import AppKit
import XCTest

/// Shared steps of the Mac UI tests that drive the app on a live local server
/// (`TEST_RUNNER_OMNIGENT_E2E_SERVER_URL`, default http://127.0.0.1:6767) and its seeded
/// sessions: the fixture session (`TEST_RUNNER_OMNIGENT_UITEST_SESSION`, from
/// `Tools/seed-ui-test-fixtures.py`) and a long transcript (`TEST_RUNNER_OMNIGENT_LONG_SESSION`,
/// from `Tools/seed-large-fixtures.py`). Tests skip when their session is not seeded.
///
/// They take the real mouse and keyboard, so run them in a VM (`vm-test.sh`), not on a Mac in use.
@MainActor
struct MacLiveUITestSupport {
  let test: XCTestCase
  let server: String

  init(_ test: XCTestCase) {
    self.test = test
    server = Self.environment["OMNIGENT_E2E_SERVER_URL"] ?? "http://127.0.0.1:6767"
  }

  nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }

  /// The seeded fixture session, or a skip when the run has none.
  func fixtureSession() throws -> String {
    try seeded("OMNIGENT_UITEST_SESSION", "Seed with Tools/seed-ui-test-fixtures.py")
  }

  /// The fixture session's workspace folder on this Mac.
  func fixtureWorkspace() throws -> URL {
    URL(
      filePath: try seeded("OMNIGENT_UITEST_WORKSPACE", "Seed with Tools/seed-ui-test-fixtures.py"),
      directoryHint: .isDirectory)
  }

  /// A seeded session with hundreds of turns, or a skip when the run has none.
  func longSession() throws -> String {
    try seeded("OMNIGENT_LONG_SESSION", "Seed with Tools/seed-large-fixtures.py")
  }

  private func seeded(_ key: String, _ how: String) throws -> String {
    guard let value = Self.environment[key], !value.isEmpty else {
      throw XCTSkip("\(how); pass TEST_RUNNER_\(key).")
    }
    return value
  }

  /// Launches the app on the server with no restored windows and tabs saved apart.
  func launch() -> XCUIApplication {
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-mac-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path, "-OmnigentNoNotificationPrompt", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "no window")
    return app
  }

  /// Launches the app on the core's offline demo server (`-OmnigentDemo`), with tabs saved apart.
  func launchDemo() -> XCUIApplication {
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-mac-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-OmnigentDemo", "YES", "-desktop.defaultServerURL", "http://127.0.0.1:6767",
      "-ApplePersistenceIgnoreState", "YES", "-OmnigentTabsDirectory", tabs.path,
      "-OmnigentNoNotificationPrompt", "YES",
    ]
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30), "no window")
    return app
  }

  /// Opens a demo session (demo-notes, demo-design, demo-question) from the sidebar and waits for
  /// its composer.
  func openDemo(_ sessionID: String, in app: XCUIApplication) {
    let row = element("session-row-\(sessionID)", in: app)
    let transcript = element("transcript-\(sessionID)", in: app)
    // Right after launch the window can still be settling on its server; a click can be lost.
    for _ in 0..<3 where !transcript.exists {
      click(row, "the \(sessionID) row", timeout: 30)
      _ = transcript.waitForExistence(timeout: 10)
    }
    XCTAssertTrue(transcript.exists, "\(sessionID) did not open\n\(app.debugDescription)")
    assertRunning(app, "after opening \(sessionID)")
  }

  /// Opens a session by its link, as the system would, and waits for its transcript.
  func open(_ sessionID: String, in app: XCUIApplication) {
    let transcript = element("transcript-\(sessionID)", in: app)
    let link = Self.sessionLink(server: server, sessionID: sessionID)
    for _ in 0..<3 where !transcript.exists {
      // Right after launch the window can still be connecting; a link then may be dropped.
      if let link { app.open(link) }
      _ = transcript.waitForExistence(timeout: 20)
    }
    XCTAssertTrue(transcript.exists, "session \(sessionID) did not open\n\(app.debugDescription)")
    assertRunning(app, "after opening \(sessionID)")
  }

  /// The session's deep link on the server.
  nonisolated static func sessionLink(server: String, sessionID: String) -> URL? {
    guard let url = URL(string: server), let host = url.host() else { return nil }
    return URL(string: "omnigent://\(host)\(url.port.map { ":\($0)" } ?? "")/c/\(sessionID)")
  }

  /// The element with `identifier`, of any type.
  func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// The elements whose identifier starts with `prefix`.
  func elements(prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", prefix))
  }

  /// The strip's tabs of one kind (chat, terminal, browser, newTab, ...).
  func tabs(_ kind: String, in app: XCUIApplication) -> XCUIElementQuery {
    elements(prefix: "tab-\(kind)-", in: app)
  }

  /// Any element whose text contains `text`.
  func text(containing text: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)
    ).firstMatch
  }

  /// Waits for `element` and clicks it, failing with `name` when it never shows.
  func click(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 10) {
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(name) is missing")
    element.click()
  }

  /// Fails when the app is no longer running in front: a crash or a hang that killed it.
  func assertRunning(
    _ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      app.state, .runningForeground, "the app is not running \(step)", file: file, line: line)
  }

  /// Polls `condition` every 0.2 s until it holds or `timeout` passes.
  func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
  }

  /// Attaches a screenshot of the app's window, kept with the result bundle.
  func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }
}
