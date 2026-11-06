import UIKit
import XCTest

/// The Safari-style tab overview on iPhone and iPad against the offline demo server: one card
/// per tab of the shown session, a close button on every card but the primary chat's, and a tap
/// that zooms back into the chosen tab.
///
/// Set `TEST_RUNNER_SESSION_TABS_SHOTS_DIR` to also write each state as `<model>-grid-<state>.png`.
final class TabGridOverviewUITests: XCTestCase {
  private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  @MainActor
  func testOverviewShowsTheSessionsTabsAsCards() throws {
    let app = launch()
    try open("demo-design", in: app)
    openOverview(in: app)
    tap(app.buttons["tab-overview-new"], "New Tab in the overview")
    tap(app.descendants(matching: .any)["newtab-browser"], "Browser on the new-tab page")
    try shot("browser")

    openOverview(in: app)
    let cards = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'tab-overview-row-'"))
    let closeButtons = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH 'tab-overview-close-'"))
    XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "the overview shows no cards")
    XCTAssertEqual(cards.count, 2, "one card each for the chat and the browser")
    XCTAssertEqual(closeButtons.count, 1, "the primary chat's card offers a close button")
    try shot("overview")
    if !isPhone {
      // The grid refits its columns to the narrower width.
      XCUIDevice.shared.orientation = .portrait
      sleep(1)
      try shot("overview-portrait")
      XCUIDevice.shared.orientation = .landscapeLeft
      sleep(1)
    }

    // Closing the browser leaves the chat's card, which cannot be closed.
    closeButtons.firstMatch.tap()
    XCTAssertTrue(
      waitForCount(cards, toBe: 1), "closing a card left \(cards.count) cards")
    XCTAssertEqual(closeButtons.count, 0)
    try shot("closed")

    // Tapping the chat's card zooms back into it.
    cards.firstMatch.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["tab-overview-sheet"].waitForNonExistence(timeout: 5),
      "the overview stayed open")
    try shot("chat")
  }

  // MARK: Helpers

  @MainActor
  private func launch() -> XCUIApplication {
    let tabs = FileManager.default.temporaryDirectory
      .appendingPathComponent("tab-grid-\(UUID().uuidString)")
    let app = XCUIApplication()
    app.launchArguments += [
      "-OmnigentDemo", "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    return app
  }

  /// The tab-count button on iPhone; Show All Tabs in the strip's overview menu on iPad.
  @MainActor
  private func openOverview(in app: XCUIApplication) {
    if isPhone {
      tap(app.buttons["tab-switcher"], "the tab switcher")
    } else {
      tap(app.buttons["tab-overview"], "the strip's overview menu")
      tap(app.buttons["Show All Tabs"], "Show All Tabs")
    }
    XCTAssertTrue(
      app.descendants(matching: .any)["tab-overview-sheet"].waitForExistence(timeout: 5),
      "the overview did not open")
  }

  @MainActor
  private func open(_ sessionID: String, in app: XCUIApplication) throws {
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"]
    for _ in 0..<3 where !row.waitForExistence(timeout: 8) {
      let back = [app.navigationBars.buttons["BackButton"], app.buttons["browser.sessions"]]
        .first(where: \.exists)
      guard let back else { break }
      back.tap()
    }
    XCTAssertTrue(row.exists, "no row for \(sessionID)")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
  }

  @MainActor
  private func waitForCount(_ query: XCUIElementQuery, toBe count: Int) -> Bool {
    let predicate = NSPredicate { _, _ in query.count == count }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
    return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
  }

  @MainActor
  private func tap(_ element: XCUIElement, _ name: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), "\(name) is missing")
    element.tap()
  }

  @MainActor
  private func shot(_ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    // The model, so each simulator's shots keep their own names ("ipad-pro-11-inch-m5").
    let device = UIDevice.current.name.lowercased()
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "-")
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(device)-grid-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["SESSION_TABS_SHOTS_DIR"] else { return }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(device)-grid-\(state).png"))
  }
}
