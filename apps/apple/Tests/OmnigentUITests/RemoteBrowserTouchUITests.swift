import UIKit
import XCTest

/// A remote browser tab on touch against a real server, runner and browser host: open it from
/// the new-tab page, take over, load the fixture page, tap, pan to scroll, and hand back.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL`, `OMNIGENT_E2E_REMOTE_SESSION_ID` and
/// `OMNIGENT_E2E_REMOTE_PAGE_URL` (the page in `Tests/Fixtures/remote-browser`), all with the
/// `TEST_RUNNER_` prefix. `TEST_RUNNER_OMNIGENT_E2E_SHOTS_DIR` also writes each step as a PNG.
final class RemoteBrowserTouchUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testRemoteTabTapsScrollsAndHandsBack() throws {
    let support = try RemoteBrowserUITestSupport.live()
    let app = support.launch()
    let toggleBox = RemoteBrowserUITestSupport.toggleBox

    try support.openRemoteTab(app) { try shot($0) }
    let surface = app.descendants(matching: .any)["remote-browser.surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 60), "the remote tab did not attach")
    let takeOver = app.buttons["remote-browser.takeOver"]
    if takeOver.waitForExistence(timeout: 10) { takeOver.tap() }
    let handBack = app.buttons["remote-browser.handBack"]
    XCTAssertTrue(handBack.waitForExistence(timeout: 10), "Take Over did not give control")

    support.load(support.page, in: app)
    XCTAssertTrue(
      support.waitForBox(.green, in: surface, timeout: 20), "the test page did not render")
    try shot("page")

    // A tap clicks: the box turns red.
    support.coordinate(css: toggleBox, in: surface).tap()
    XCTAssertTrue(support.waitForBox(.red, in: surface), "a tap did not reach the page")
    try shot("tapped")

    // A pan scrolls the list under the finger (a short press first, below the long-press time).
    let start = support.coordinate(css: CGPoint(x: 400, y: 650), in: surface)
    let end = support.coordinate(css: CGPoint(x: 400, y: 350), in: surface)
    start.press(forDuration: 0.05, thenDragTo: end)
    Thread.sleep(forTimeInterval: 1.5)
    try shot("scrolled")

    // Handed back, taps no longer reach the page.
    handBack.tap()
    XCTAssertTrue(takeOver.waitForExistence(timeout: 10), "no Take Over after handing back")
    support.coordinate(css: toggleBox, in: surface).tap()
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(try support.boxColor(surface), .red, "a tap reached the page after Hand Back")
    try shot("handed-back")

    takeOver.tap()
    XCTAssertTrue(handBack.waitForExistence(timeout: 10), "no Hand Back after taking over")
    support.coordinate(css: toggleBox, in: surface).tap()
    XCTAssertTrue(
      support.waitForBox(.green, in: surface), "a tap after Take Over did not reach the page")
    try shot("taken-back")
  }

  @MainActor
  private func shot(_ name: String) throws {
    try RemoteBrowserUITestSupport.shot("rb-ipad-\(name)", in: self)
  }
}
