import AppKit
import XCTest

/// The connected app end to end against a running server whose session streams replies from a
/// mock model: the session list, opening a session, sending and watching the reply stream into
/// the transcript, stopping a turn, and (when `OMNIGENT_E2E_RECONNECT` is set) surviving a server
/// restart without duplicate rows.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_E2E_SESSION_ID` (pass
/// them with the `TEST_RUNNER_` prefix to `xcodebuild test`). Screenshots are attached to the
/// result bundle; export them with `xcrun xcresulttool export attachments`.
final class NativeAppE2EUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testConnectedSessionStreamsAndStops() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _SESSION_ID to run.")
    }
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    let window = app.windows.firstMatch

    // The row is a text, or a button while the pointer is over it (its hover actions).
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    save(window, "connected")
    // The first connect asks for notification permission, which can take focus from the window
    // just as the row is clicked; click again until the conversation opens.
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      window.click()
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")
    waitForComposer(app, timeout: 30)
    save(window, "opened")

    send("Say hello, please.", app: app, input: input)
    reply(app, tagged: "hello")
    save(window, "streaming")
    waitForTurnEnd(app)
    save(window, "turn-complete")

    checkInterrupt(app, window: window, input: input)

    if environment["OMNIGENT_E2E_RECONNECT"] != nil {
      try checkReconnect(app, window: window, input: input)
    }
  }

  /// Stops a slow reply with the composer's Stop button; the reply is marked interrupted and
  /// does not run to its end.
  @MainActor
  private func checkInterrupt(_ app: XCUIApplication, window: XCUIElement, input: XCUIElement) {
    send("Now take your time.", app: app, input: input)
    let slow = reply(app, tagged: "slow")
    save(window, "slow-streaming")
    let stop = app.buttons["composer-stop"]
    XCTAssertTrue(stop.waitForExistence(timeout: 10))
    stop.click()
    let rowID = slow.identifier.replacingOccurrences(of: "message-text-", with: "")
    let interrupted = app.descendants(matching: .any)["message-interrupted-\(rowID)"]
    XCTAssertTrue(interrupted.waitForExistence(timeout: 30), "the stopped turn was not marked")
    let slowText = slow.label + String(describing: slow.value ?? "")
    XCTAssertFalse(slowText.contains("word120 word1 word2"), "the slow turn ran to the end")
    save(window, "interrupted")
  }

  /// Waits while the harness kills and restarts the server, then sends again and checks that
  /// every transcript row appears once.
  @MainActor
  private func checkReconnect(_ app: XCUIApplication, window: XCUIElement, input: XCUIElement)
    throws
  {
    // The banner over the detail: the live-updates status while the server is gone.
    let reconnecting = app.descendants(matching: .any)["connection.status"]
    XCTAssertTrue(
      reconnecting.waitForExistence(timeout: 180), "no reconnecting state after the server stopped")
    save(window, "server-down")
    waitForComposer(app, timeout: 180)
    let gone = NSPredicate(format: "exists == false")
    expectation(for: gone, evaluatedWith: reconnecting)
    waitForExpectations(timeout: 180)
    save(window, "reconnected")

    send("Are you still there?", app: app, input: input)
    reply(app, tagged: "third")
    waitForTurnEnd(app)
    save(window, "after-reconnect")
    // The transcript is lazy, so only rows on screen are in the tree: those must be distinct,
    // and this run's replies around the restart must each appear once.
    let rows = messageIDs(app)
    XCTAssertEqual(Set(rows).count, rows.count, "a transcript row appears twice: \(rows)")
    for name in ["slow", "third"] {
      let marker = "[\(tag)-\(name)]"
      let copies = app.descendants(matching: .any).matching(
        NSPredicate(
          format: "identifier BEGINSWITH 'message-text-' AND (label CONTAINS %@ OR value CONTAINS %@)",
          marker, marker))
      XCTAssertLessThanOrEqual(copies.count, 1, "\(marker) appears \(copies.count) times")
    }
  }

  /// The turn is over when the composer's Stop button gives way to Send again.
  @MainActor
  private func waitForTurnEnd(_ app: XCUIApplication) {
    let stop = app.descendants(matching: .any)["composer-stop"]
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: stop)
    waitForExpectations(timeout: 90)
  }

  /// The composer shows `composer-unavailable` until the session has loaded.
  @MainActor
  private func waitForComposer(_ app: XCUIApplication, timeout: TimeInterval) {
    let unavailable = app.descendants(matching: .any)["composer-unavailable"]
    expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: unavailable)
    waitForExpectations(timeout: timeout)
  }

  @MainActor
  private func send(_ text: String, app: XCUIApplication, input: XCUIElement) {
    // A system prompt can take focus mid-test, so type again until the editor holds the text.
    for _ in 0..<3 where !String(describing: input.value ?? "").contains(text) {
      app.windows.firstMatch.click()
      input.click()
      app.typeKey("a", modifierFlags: .command)
      app.typeText(text)
    }
    XCTAssertTrue(String(describing: input.value ?? "").contains(text), "the composer did not take \(text)")
    let sendButton = app.buttons["composer-send"]
    XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
    sendButton.click()
  }

  /// This run's reply `[<tag>-<name>]` (the mock prefixes each reply with the run's tag).
  @discardableResult
  @MainActor
  private func reply(_ app: XCUIApplication, tagged name: String) -> XCUIElement {
    let marker = "[\(tag)-\(name)]"
    let reply = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'message-text-' AND (label CONTAINS %@ OR value CONTAINS %@)",
        marker, marker)
    ).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 60), "no reply \(marker)")
    return reply
  }

  private var tag: String {
    ProcessInfo.processInfo.environment["OMNIGENT_E2E_TAG"] ?? "run"
  }

  @MainActor
  private func messageIDs(_ app: XCUIApplication) -> [String] {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'message-text-'")
    ).allElementsBoundByIndex.map(\.identifier)
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
