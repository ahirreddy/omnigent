import UIKit
import XCTest

/// A remote browser tab on touch against a real server, runner and browser host: open it from
/// the new-tab page, take over, load the fixture page, tap, pan to scroll, and hand back.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL`, `OMNIGENT_E2E_REMOTE_SESSION_ID` and
/// `OMNIGENT_E2E_REMOTE_PAGE_URL` (the page in `Tests/Fixtures/remote-browser`), all with the
/// `TEST_RUNNER_` prefix. `TEST_RUNNER_OMNIGENT_E2E_SHOTS_DIR` also writes each step as a PNG.
final class RemoteBrowserTouchUITests: XCTestCase {
  /// The host's default viewport in CSS pixels.
  private let viewport = CGSize(width: 1280, height: 800)
  /// The fixture's box that toggles between green and red on every mouse down.
  private let toggleBox = CGPoint(x: 1050, y: 190)

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
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_REMOTE_SESSION_ID"],
      let page = environment["OMNIGENT_E2E_REMOTE_PAGE_URL"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL, _REMOTE_SESSION_ID and _PAGE_URL.")
    }
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-OmnigentRemoteBrowser", "YES",
    ]
    app.launch()

    try openRemoteTab(app, sessionID: sessionID)
    let surface = app.descendants(matching: .any)["remote-browser.surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 60), "the remote tab did not attach")
    let takeOver = app.buttons["remote-browser.takeOver"]
    if takeOver.waitForExistence(timeout: 10) { takeOver.tap() }
    let handBack = app.buttons["remote-browser.handBack"]
    XCTAssertTrue(handBack.waitForExistence(timeout: 10), "Take Over did not give control")

    let address = app.textFields["remote-browser.address"]
    XCTAssertTrue(address.waitForExistence(timeout: 10), "no address field")
    address.tap()
    address.typeText(page + "\n")
    XCTAssertTrue(waitForBox(.green, in: surface, timeout: 20), "the test page did not render")
    try shot("page")

    // A tap clicks: the box turns red.
    coordinate(css: toggleBox, in: surface).tap()
    XCTAssertTrue(waitForBox(.red, in: surface), "a tap did not reach the page")
    try shot("tapped")

    // A pan scrolls the list under the finger (a short press first, below the long-press time).
    let start = coordinate(css: CGPoint(x: 400, y: 650), in: surface)
    let end = coordinate(css: CGPoint(x: 400, y: 350), in: surface)
    start.press(forDuration: 0.05, thenDragTo: end)
    Thread.sleep(forTimeInterval: 1.5)
    try shot("scrolled")

    // Handed back, taps no longer reach the page.
    handBack.tap()
    XCTAssertTrue(takeOver.waitForExistence(timeout: 10), "no Take Over after handing back")
    coordinate(css: toggleBox, in: surface).tap()
    Thread.sleep(forTimeInterval: 1.5)
    XCTAssertEqual(try boxColor(surface), .red, "a tap reached the page after Hand Back")
    try shot("handed-back")

    takeOver.tap()
    XCTAssertTrue(handBack.waitForExistence(timeout: 10), "no Hand Back after taking over")
    coordinate(css: toggleBox, in: surface).tap()
    XCTAssertTrue(waitForBox(.green, in: surface), "a tap after Take Over did not reach the page")
    try shot("taken-back")
  }

  /// The new-tab page's Remote Browser launcher: this session, default profile.
  @MainActor
  private func openRemoteTab(_ app: XCUIApplication, sessionID: String) throws {
    let launcher = app.buttons["newtab-remote-browser"].firstMatch
    if !launcher.waitForExistence(timeout: 20) {
      app.buttons["tab-new"].firstMatch.tap()
    }
    XCTAssertTrue(launcher.waitForExistence(timeout: 20), "the new-tab page has no Remote Browser")
    try shot("new-tab")
    launcher.tap()
    let session = app.buttons["newtab-remote-browser-\(sessionID)"].firstMatch
    XCTAssertTrue(session.waitForExistence(timeout: 10), "the launcher does not list the session")
    session.tap()
    // UIKit drops identifiers inside a submenu: match the profile by its title there.
    let profile = app.buttons.matching(
      NSPredicate(
        format: "identifier == %@ OR label == 'default'",
        "newtab-remote-browser-\(sessionID)-default")
    ).firstMatch
    XCTAssertTrue(profile.waitForExistence(timeout: 10), "no default profile to choose")
    profile.tap()
  }

  /// The point of `surface` showing a CSS point of the remote viewport, letterboxed.
  @MainActor
  private func coordinate(css point: CGPoint, in surface: XCUIElement) -> XCUICoordinate {
    let offset = viewOffset(css: point, size: surface.frame.size)
    return surface.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: offset.x, dy: offset.y))
  }

  private func viewOffset(css point: CGPoint, size: CGSize) -> CGPoint {
    let scale = min(size.width / viewport.width, size.height / viewport.height)
    let originX = (size.width - viewport.width * scale) / 2
    let originY = (size.height - viewport.height * scale) / 2
    return CGPoint(x: originX + point.x * scale, y: originY + point.y * scale)
  }

  private enum BoxColor { case green, red, other }

  /// The toggle box's colour in a screenshot of the decoded video.
  @MainActor
  private func boxColor(_ surface: XCUIElement) throws -> BoxColor {
    let image = try XCTUnwrap(surface.screenshot().image.cgImage)
    let pixelScale = CGFloat(image.width) / surface.frame.width
    let point = viewOffset(css: toggleBox, size: surface.frame.size)
    // `data: nil`: Core Graphics owns the buffer; the initializer is only typed unsafe.
    let context = try XCTUnwrap(
      unsafe CGContext(
        data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(
      image,
      in: CGRect(
        x: -point.x * pixelScale, y: -(CGFloat(image.height) - point.y * pixelScale),
        width: CGFloat(image.width), height: CGFloat(image.height)))
    // One RGBA pixel, read back through an image so no raw pointer is needed.
    let pixel = try XCTUnwrap(context.makeImage()?.dataProvider?.data) as Data
    let (red, green) = (Int(pixel[0]), Int(pixel[1]))
    if green > red + 50 { return .green }
    if red > green + 50 { return .red }
    return .other
  }

  @MainActor
  private func waitForBox(_ expected: BoxColor, in surface: XCUIElement, timeout: TimeInterval = 5)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (try? boxColor(surface)) == expected { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return false
  }

  @MainActor
  private func shot(_ name: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "e2e-remote-browser-touch-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_E2E_SHOTS_DIR"] else {
      return
    }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("rb-ipad-\(name).png"))
  }
}
