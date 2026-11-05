import UIKit
import XCTest

/// Shared steps of the UI tests that tap through the app on the local server
/// (`TEST_RUNNER_OMNIGENT_SERVER`, default http://127.0.0.1:6767) and its seeded fixture session
/// (`TEST_RUNNER_OMNIGENT_UITEST_SESSION`, from `Tools/seed-ui-test-fixtures.py`; `just
/// apple-uitest-ios` seeds and passes it).
@MainActor
struct LiveServerUITestSupport {
  let server: String
  let test: XCTestCase

  init(_ test: XCTestCase) {
    self.test = test
    server = ProcessInfo.processInfo.environment["OMNIGENT_SERVER"] ?? "http://127.0.0.1:6767"
  }

  var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  /// The seeded fixture session, or a skip when the run has none.
  /// - Returns: Its id.
  /// - Throws: `XCTSkip`.
  func fixtureSession() throws -> String {
    guard let id = ProcessInfo.processInfo.environment["OMNIGENT_UITEST_SESSION"] else {
      throw XCTSkip(
        "Seed with Tools/seed-ui-test-fixtures.py; pass TEST_RUNNER_OMNIGENT_UITEST_SESSION.")
    }
    return id
  }

  /// Launches the app on the server with no restored state, opening `sessionID` when given.
  /// - Parameters:
  ///   - sessionID: The session to open, as its link would.
  ///   - extra: More launch arguments.
  /// - Returns: The app.
  func launch(opening sessionID: String? = nil, extra: [String] = []) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += ["-omnigent.lastServer", server] + Self.freshStateArguments
    if let sessionID, let link = Self.sessionLink(server: server, sessionID: sessionID) {
      app.launchArguments += ["-OmnigentOpenURL", link]
    }
    app.launchArguments += extra
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    return app
  }

  /// No restored windows, notification prompt or right panel (whose last state is the default).
  nonisolated static let freshStateArguments = [
    "-ApplePersistenceIgnoreState", "YES", "-OmnigentNoNotificationPrompt", "YES",
    "-omnigent:default-workspace-panel", "collapsed",
  ]

  /// The session's deep link on `server`, which debug builds open at launch (`-OmnigentOpenURL`).
  nonisolated static func sessionLink(server: String, sessionID: String) -> String? {
    guard let url = URL(string: server), let host = url.host() else { return nil }
    return "omnigent://\(host)\(url.port.map { ":\($0)" } ?? "")/c/\(sessionID)"
  }

  /// The element with `identifier`, of any type.
  func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// The first element whose identifier starts with `prefix`.
  func element(prefix: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
  }

  /// Waits for `element` and taps it, failing with `name` when it never shows.
  func tap(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 10) {
    XCTAssertTrue(element.waitForExistence(timeout: timeout), "\(name) is missing")
    element.tap()
  }

  /// Taps `field` until it has the keyboard (a loaded machine can drop the first tap's focus),
  /// then types `text`.
  func type(_ text: String, into field: XCUIElement) {
    let focused = { (field.value(forKey: "hasKeyboardFocus") as? Bool) == true }
    for _ in 0..<3 where !focused() {
      field.tap()
      _ = waitUntil(timeout: 5, focused)
    }
    field.typeText(text)
  }

  /// Goes back to the session list: an iPhone reopens the chat tab its last run left open.
  func showSessionList(_ app: XCUIApplication) {
    let list = element("server-switcher", in: app)
    for _ in 0..<3 where !list.waitForExistence(timeout: 10) {
      let back = app.navigationBars.buttons.firstMatch
      if back.exists { back.tap() }
    }
    XCTAssertTrue(list.exists, "the session list did not show")
  }

  /// Waits for the session's transcript.
  func waitForTranscript(_ sessionID: String, in app: XCUIApplication) {
    XCTAssertTrue(
      element("transcript-\(sessionID)", in: app).waitForExistence(timeout: 30),
      "the session did not open")
  }

  /// Closes an open menu or popover by tapping the window's trailing edge.
  func dismissMenu(_ app: XCUIApplication) {
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
  }

  /// Polls `condition` until it holds or `timeout` passes.
  func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
  }

  /// Attaches a screenshot named `<device>-<state>`.
  func shot(_ state: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "\(isPhone ? "iphone" : "ipad")-\(state)"
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }
}
