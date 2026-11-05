import UIKit
import XCTest

/// A side chat against the live local server: Add > Start a new side chat opens an empty side
/// chat that exists only on the device, and the first send creates it on the server and shows
/// it as a side chat (its own empty transcript, "Side chat of <session>", "Side chat 1" tab).
///
/// Needs `TEST_RUNNER_OMNIGENT_E2E_SERVER_URL` and `TEST_RUNNER_SIDE_CHAT_PARENT` (a session the
/// server's host runs). The test logs `SIDECHAT <state> <epoch>` so a caller can compare the
/// server's sessions before and after the send; `TEST_RUNNER_SIDE_CHAT_HOLD` seconds (default 0)
/// keeps the unsent side chat open for that check. `TEST_RUNNER_SIDE_CHAT_SHOTS_DIR` also writes
/// screenshots there.
final class SideChatUITests: XCTestCase {
  private let environment = ProcessInfo.processInfo.environment
  private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  @MainActor
  func testSideChatIsCreatedByItsFirstMessage() throws {
    let app = try launch()
    let input = shown(app.textViews, "composer-input", timeout: 20)
    XCTAssertTrue(input.exists, "the parent session did not open")
    var add = shown(app.buttons, "composer-add", timeout: 3)
    if !add.exists || !add.isHittable {
      input.tap()
      add = shown(app.buttons, "composer-add", timeout: 10)
    }
    tap(add, "Add")
    tap(app.buttons["Start a new side chat"], "Start a new side chat")

    let anyElement = app.descendants(matching: .any)
    XCTAssertNotNil(shownMatch(anyElement, "sidechat-pending", timeout: 10), "no new side chat")
    XCTAssertTrue(app.descendants(matching: .any)["sidechat-empty"].exists)
    XCTAssertTrue(app.descendants(matching: .any)["sidechat-open-parent"].exists)
    log("pending")
    try shot(app, "pending")
    let hold = UInt32(environment["SIDE_CHAT_HOLD"] ?? "") ?? 0
    if hold > 0 { sleep(hold) }

    let question = "Side question \(Int(Date().timeIntervalSince1970))"
    let focused = app.textViews.matching(
      NSPredicate(format: "identifier == 'composer-input' AND hasFocus == true")
    ).firstMatch
    for _ in 0..<3 where !focused.exists {
      tap(shown(app.textViews, "composer-input", timeout: 10), "the side chat's composer")
      _ = focused.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(focused.exists, "the side chat's composer did not take focus")
    focused.typeText(question)
    log("send")
    tap(shown(app.buttons, "composer-send", timeout: 10), "Send")

    let sent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", question)).firstMatch
    XCTAssertTrue(sent.waitForExistence(timeout: 30), "the first message did not show")
    XCTAssertTrue(
      waitUntilGone(anyElement, "sidechat-pending", timeout: 5), "still the unsent side chat")
    XCTAssertTrue(
      app.descendants(matching: .any)["sidechat-open-parent"].exists,
      "the side chat does not link to its session")
    log("created")
    _ = app.buttons["composer-stop"].waitForNonExistence(timeout: 60)
    try shot(app, "created")
    try expectTab(app, titled: "Side chat 1")
  }

  // MARK: Helpers

  /// The shown tab's `identifier` element once one appears. On iPad the tabs kept alive under the
  /// shown one still list their own elements, covered and so not hittable.
  @MainActor
  private func shownMatch(_ query: XCUIElementQuery, _ identifier: String, timeout: TimeInterval)
    -> XCUIElement?
  {
    let matches = query.matching(identifier: identifier)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if let hittable = matches.allElementsBoundByIndex.first(where: \.isHittable) {
        return hittable
      }
      usleep(250_000)
    } while Date() < deadline
    return nil
  }

  /// ``shownMatch(_:_:timeout:)``, or the first match for the caller's tap to report.
  @MainActor
  private func shown(_ query: XCUIElementQuery, _ identifier: String, timeout: TimeInterval)
    -> XCUIElement
  {
    shownMatch(query, identifier, timeout: timeout)
      ?? query.matching(identifier: identifier)
      .firstMatch
  }

  /// Whether the shown tab stops showing an `identifier` element within `timeout`.
  @MainActor
  private func waitUntilGone(_ query: XCUIElementQuery, _ identifier: String, timeout: TimeInterval)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    while shownMatch(query, identifier, timeout: 0) != nil {
      guard Date() < deadline else { return false }
      usleep(250_000)
    }
    return true
  }

  @MainActor
  private func setting(_ name: String) throws -> String {
    guard let value = environment[name] else {
      throw XCTSkip("Set TEST_RUNNER_\(name) to run.")
    }
    return value
  }

  /// The app on the live server, showing the parent session.
  @MainActor
  private func launch() throws -> XCUIApplication {
    let server = try setting("OMNIGENT_E2E_SERVER_URL")
    let parent = try setting("SIDE_CHAT_PARENT")
    let host = URL(string: server)?.host(percentEncoded: false) ?? "127.0.0.1"
    let port = URL(string: server)?.port.map { ":\($0)" } ?? ""
    // A first launch asks for notifications; the prompt would cover the composer.
    addUIInterruptionMonitor(withDescription: "Notifications") { alert in
      let decline = alert.buttons["Don\u{2019}t Allow"]
      guard decline.exists else { return false }
      decline.tap()
      return true
    }
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    try openURL("omnigent://\(host)\(port)/c/\(parent)")
    return app
  }

  /// Opens `link` as the system does, accepting its "Open in" prompt.
  @MainActor
  private func openURL(_ link: String) throws {
    XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: link), "bad link \(link)"))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons["Open"]
    if open.waitForExistence(timeout: 5) { open.tap() }
  }

  /// The strip (iPad) or the tab overview (iPhone) lists the side chat's tab.
  @MainActor
  private func expectTab(_ app: XCUIApplication, titled title: String) throws {
    if isPhone {
      tap(app.buttons["tab-switcher"], "the tab switcher")
      XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), "no \(title) tab")
      try shot(app, "tabs")
      tap(app.buttons["tab-overview-done"], "Done")
    } else {
      // A strip tab is one element labelled with its title.
      let tab = app.descendants(matching: .any)
        .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-' AND label == %@", title))
        .firstMatch
      XCTAssertTrue(tab.waitForExistence(timeout: 5), "no \(title) tab")
    }
  }

  @MainActor
  private func tap(_ element: XCUIElement, _ name: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), "\(name) is missing")
    element.tap()
  }

  private func log(_ state: String) {
    NSLog("SIDECHAT %@ %d", state, Int(Date().timeIntervalSince1970))
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let device = isPhone ? "iphone" : "ipad"
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(device)-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = environment["SIDE_CHAT_SHOTS_DIR"] else { return }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(state).png"))
  }
}
