import UIKit
import XCTest

/// The sidebar's Load more and the transcript's turn rail, against the local server
/// (`TEST_RUNNER_OMNIGENT_SERVER`, default http://127.0.0.1:6767) with more sessions than one
/// page. Set `TEST_RUNNER_PHONE_SHOTS_DIR` to also write each state as `rail-<state>.png`.
final class RailPagingUITests: XCTestCase {
  private var server: String {
    ProcessInfo.processInfo.environment["OMNIGENT_SERVER"] ?? "http://127.0.0.1:6767"
  }

  @MainActor
  func testLoadMoreAddsTheNextPageOfSessions() throws {
    let app = launch()
    let sidebar = app.descendants(matching: .any)["sidebar"].firstMatch
    XCTAssertTrue(sidebar.waitForExistence(timeout: 30), "the server did not connect")
    let loadMore = app.buttons["sidebar-load-more"]
    // Scrolling to the row reads up to three pages by itself, as the web; then it waits.
    for _ in 0..<4 {
      try reveal(loadMore, in: sidebar)
      sleep(1)
      XCTAssertTrue(waitForLabel(loadMore, "Load more"), "a page did not finish loading")
    }
    let before = count(loadMore)
    XCTAssertGreaterThan(before, 0, "Load more reports no loaded sessions")
    try shot(app, "load-more-before")
    loadMore.tap()
    // The new page pushes the row down, out of the list's loaded cells; scroll back to it.
    var after = before
    for _ in 0..<10 where after <= before {
      sleep(2)
      try reveal(loadMore, in: sidebar)
      after = count(loadMore)
    }
    XCTAssertGreaterThan(after, before, "Load more did not add a page")
    try shot(app, "load-more-after")
  }

  @MainActor
  func testTurnRailTickScrollsToItsTurn() throws {
    let app = launch()
    XCTAssertTrue(
      app.descendants(matching: .any)["sidebar"].firstMatch.waitForExistence(timeout: 30),
      "the server did not connect")
    let sessionID =
      ProcessInfo.processInfo.environment["OMNIGENT_SESSION"] ?? "efb05e5b065c42f78ff2271c7c97fa9b"
    let host = try XCTUnwrap(URL(string: server)?.host(), "no host in \(server)")
    let port = URL(string: server)?.port.map { ":\($0)" } ?? ""
    try openURL("omnigent://\(host)\(port)/c/\(sessionID)")
    let transcript = app.descendants(matching: .any)["transcript-\(sessionID)"].firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 20), "the link did not open the session")
    let ticks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'turn-rail-tick-'"))
    guard UIDevice.current.userInterfaceIdiom == .pad else {
      // The web leaves the rail out at phone widths.
      sleep(2)
      XCTAssertFalse(ticks.firstMatch.exists, "the turn rail shows on a phone")
      try shot(app, "phone-no-rail")
      return
    }
    XCTAssertTrue(ticks.firstMatch.waitForExistence(timeout: 15), "no turn rail")
    XCTAssertGreaterThan(ticks.count, 1, "the rail has fewer than two turns")
    let first = ticks.element(boundBy: 0)
    // The session opens on its latest turn, so the first turn is not the active one.
    XCTAssertFalse(first.isSelected, "the first turn is already active")
    try shot(app, "rail-before")
    first.tap()
    let active = expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: first)
    wait(for: [active], timeout: 10)
    try shot(app, "rail-after")
  }

  // MARK: Helpers

  /// The sessions the Load more row says are loaded.
  @MainActor
  private func count(_ loadMore: XCUIElement) -> Int {
    // A snapshot, not a query: the row comes and goes as pages push it out of view.
    let value = (try? loadMore.snapshot())?.value as? String ?? ""
    return Int(value.split(separator: " ").first ?? "") ?? 0
  }

  @MainActor
  private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
    let done = expectation(for: NSPredicate(format: "label == %@", label), evaluatedWith: element)
    return XCTWaiter().wait(for: [done], timeout: 20) == .completed
  }

  /// Scrolls the sidebar until `element` can be tapped.
  @MainActor
  private func reveal(_ element: XCUIElement, in list: XCUIElement) throws {
    for _ in 0..<60 where !isOnScreen(element, in: list) {
      list.swipeUp(velocity: .fast)
    }
    XCTAssertTrue(isOnScreen(element, in: list), "Load more never came into view")
  }

  /// Whether `element` is laid out inside `list`'s frame; a recycled off-screen cell has no
  /// frame to ask hittability of.
  @MainActor
  private func isOnScreen(_ element: XCUIElement, in list: XCUIElement) -> Bool {
    guard let frame = (try? element.snapshot())?.frame else { return false }
    return !frame.isEmpty && list.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
  }

  /// Opens `link` as the system does, accepting its "Open in" prompt.
  @MainActor
  private func openURL(_ link: String) throws {
    XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: link), "bad link \(link)"))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons["Open"]
    if open.waitForExistence(timeout: 5) { open.tap() }
  }

  @MainActor
  private func launch() -> XCUIApplication {
    addUIInterruptionMonitor(withDescription: "Notifications") { alert in
      let decline = alert.buttons["Don\u{2019}t Allow"]
      guard decline.exists else { return false }
      decline.tap()
      return true
    }
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentNoNotificationPrompt", "YES",
    ]
    app.launch()
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    return app
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = state
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["PHONE_SHOTS_DIR"] else { return }
    let idiom = UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "phone"
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("rail-\(idiom)-\(state).png"))
  }
}
