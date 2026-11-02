import UIKit
import XCTest

/// iOS viewport modes and touch (design doc section 16) against the real host: pinch zoom with
/// taps mapped through the zoom, grabbing a desktop page's scroll bar, Mobile Size scrolling
/// with momentum, and copy and paste through the edit menu. Same environment as
/// `RemoteBrowserTouchUITests`; shots are `rb-ios-<ipad|iphone>-<step>.png`.
final class RemoteBrowserViewportUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  // MARK: Desktop page: pinch zoom and the scroll bar

  @MainActor
  func testPinchZoomMapsTapsAndTheScrollBarDrags() throws {
    let support = try RemoteBrowserUITestSupport.live()
    let (app, surface) = try openControlledTab(support, mode: "keep")
    support.load(support.page, in: app)
    XCTAssertTrue(
      support.waitForBox(.green, in: surface, timeout: 20), "the test page did not render")
    try shot("keep")
    try checkPinchZoom(support, surface: surface)

    // A drag that starts on the page's scroll bar moves the thumb, not the content.
    support.load(support.page("mobile.html"), in: app)
    support.waitFor("the long page in desktop layout", in: surface) { $0["w"] == "1280" }
    let top = support.coordinate(css: CGPoint(x: 1274, y: 40), in: surface)
    let lower = support.coordinate(css: CGPoint(x: 1274, y: 440), in: surface)
    // A deliberate drag, as a person grabs a thumb (the client shows overlay bars first).
    top.press(forDuration: 0.05, thenDragTo: lower, withVelocity: .slow, thenHoldForDuration: 0.3)
    // Dragging the thumb 400 px moves the 10,000 px page by thousands of pixels; dragging the
    // content would move it by about 400.
    support.waitFor("the scroll bar drag", in: surface) { Int($0["sy"] ?? "") ?? 0 > 2000 }
    try shot("scrollbar-drag")
  }

  /// Pinch out, tap the zoomed box (input maps through the zoom), double tap back.
  @MainActor
  private func checkPinchZoom(_ support: RemoteBrowserUITestSupport, surface: XCUIElement) throws {
    let boxSpot = support.viewOffset(
      css: RemoteBrowserUITestSupport.toggleBox, size: surface.frame.size)
    surface.pinch(withScale: 2.2, velocity: 2)
    expectation(for: NSPredicate(format: "value CONTAINS 'zoomed'"), evaluatedWith: surface)
    waitForExpectations(timeout: 10)
    XCTAssertNotEqual(
      try support.color(atView: boxSpot, in: surface), .green, "the pinch did not zoom")
    try shot("zoomed")

    let size = surface.frame.size
    let candidates = stride(from: 0.55, through: 0.98, by: 0.06).flatMap { across in
      stride(from: 0.02, through: 0.6, by: 0.06).map { down in
        CGPoint(x: size.width * across, y: size.height * down)
      }
    }
    let green = try XCTUnwrap(
      try candidates.first { try support.color(atView: $0, in: surface) == .green },
      "the zoomed box is not on screen")
    surface.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: green.x, dy: green.y)).tap()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, try support.color(atView: green, in: surface) != .red {
      Thread.sleep(forTimeInterval: 0.2)
    }
    XCTAssertEqual(
      try support.color(atView: green, in: surface), .red, "a tap on the zoomed box missed")
    try shot("zoomed-tap")

    surface.doubleTap()
    expectation(for: NSPredicate(format: "NOT (value CONTAINS 'zoomed')"), evaluatedWith: surface)
    waitForExpectations(timeout: 10)
  }

  // MARK: Mobile Size: momentum, rubber band, copy and paste

  @MainActor
  func testMobileSizeScrollsWithMomentumAndCopiesAndPastes() throws {
    let support = try RemoteBrowserUITestSupport.live()
    let (app, surface) = try openControlledTab(support, mode: "mobile")
    support.load(support.page("mobile.html"), in: app)
    let width = Int(surface.frame.width.rounded())
    support.waitFor("a viewport of the view's size", in: surface) { fields in
      abs((Int(fields["w"] ?? "") ?? 0) - width) <= 1 && fields["touch"] == "5"
        && (Double(fields["dpr"] ?? "") ?? 1) > 1
    }
    try shot("mobile")
    try checkMomentum(support, surface: surface)
    try checkCopyAndPaste(support, app: app, surface: surface)
  }

  /// A flick keeps scrolling after the finger lifts; pulling down at the top only rubber-bands.
  @MainActor
  private func checkMomentum(_ support: RemoteBrowserUITestSupport, surface: XCUIElement) throws {
    func scrollY() -> Int { Int(support.report(surface)["sy"] ?? "") ?? 0 }
    surface.swipeUp(velocity: .fast)
    Thread.sleep(forTimeInterval: 0.25)
    let early = scrollY()
    Thread.sleep(forTimeInterval: 2)
    let settled = scrollY()
    XCTAssertGreaterThan(settled, early + 100, "no momentum after the finger lifted")
    try shot("momentum")
    for _ in 0..<12 where scrollY() > 0 {
      surface.swipeDown(velocity: .fast)
      Thread.sleep(forTimeInterval: 0.6)
    }
    support.waitFor("the top of the page", in: surface) { $0["sy"] == "0" }
    surface.swipeDown(velocity: .slow)
    Thread.sleep(forTimeInterval: 1)
    XCTAssertEqual(support.report(surface)["sy"], "0", "pulling past the top scrolled the page")
  }

  /// Types with the software keyboard, then copies a word and pastes it over another through
  /// the edit menu: the text goes through this device's pasteboard.
  @MainActor
  private func checkCopyAndPaste(
    _ support: RemoteBrowserUITestSupport, app: XCUIApplication, surface: XCUIElement
  ) throws {
    // Mobile Size draws the page at 1 CSS px per point from the surface's corner.
    let origin = surface.coordinate(withNormalizedOffset: .zero)
    origin.withOffset(CGVector(dx: 150, dy: 42)).tap()
    XCTAssertTrue(
      app.keyboards.firstMatch.waitForExistence(timeout: 10), "no software keyboard for the field")
    app.typeText("hello world")
    support.waitFor("the typed text", in: surface) { $0["value"] == "hello world" }
    try shot("typed")
    origin.withOffset(CGVector(dx: 94, dy: 42)).press(forDuration: 1.0)
    try tapEditMenuItem("Copy", in: app)
    origin.withOffset(CGVector(dx: 40, dy: 42)).press(forDuration: 1.0)
    try tapEditMenuItem("Paste", in: app)
    support.waitFor("the pasted word", in: surface) { $0["value"] == "world world" }
    try shot("pasted")
  }

  // MARK: Steps

  /// Launches, opens a remote tab, takes over and picks a viewport mode from the menu.
  @MainActor
  private func openControlledTab(_ support: RemoteBrowserUITestSupport, mode: String) throws -> (
    XCUIApplication, XCUIElement
  ) {
    let app = support.launch()
    try support.openRemoteTab(app) { try shot($0) }
    let surface = app.descendants(matching: .any)["remote-browser.surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 60), "the remote tab did not attach")
    let takeOver = app.buttons["remote-browser.takeOver"]
    if takeOver.waitForExistence(timeout: 10) { takeOver.tap() }
    XCTAssertTrue(
      app.buttons["remote-browser.handBack"].waitForExistence(timeout: 10),
      "Take Over did not give control")
    let menu = app.buttons["remote-browser.viewport"].firstMatch
    XCTAssertTrue(menu.waitForExistence(timeout: 10), "no viewport menu")
    menu.tap()
    let item = app.buttons["remote-browser.viewport.\(mode)"].firstMatch
    XCTAssertTrue(item.waitForExistence(timeout: 5), "no \(mode) item in the viewport menu")
    try shot("menu")
    item.tap()
    return (app, surface)
  }

  @MainActor
  private func tapEditMenuItem(_ title: String, in app: XCUIApplication) throws {
    let menuItem = app.menuItems[title]
    let button = app.buttons[title]
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, !menuItem.exists, !button.exists {
      Thread.sleep(forTimeInterval: 0.1)
    }
    try shot("edit-menu-\(title.lowercased())")
    XCTAssertTrue(menuItem.exists || button.exists, "no \(title) in the edit menu")
    (menuItem.exists ? menuItem : button).tap()
    // Paste from the edit menu is user intent and does not ask; if the system asks, allow it.
    let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Paste"]
    if allow.waitForExistence(timeout: 1) { allow.tap() }
  }

  /// A screenshot named for the device class.
  @MainActor
  private func shot(_ name: String) throws {
    let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
    try RemoteBrowserUITestSupport.shot("rb-ios-\(device)-\(name)", in: self)
  }
}
