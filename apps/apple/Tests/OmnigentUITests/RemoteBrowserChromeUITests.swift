import UIKit
import XCTest

/// How much of the screen the remote tab's chrome takes in each viewport mode, against the real
/// host: the surface's frame against the window's and the bars' frames, written to the log as
/// `RBCHROME` lines, with a shot per mode. Same environment as `RemoteBrowserTouchUITests`.
final class RemoteBrowserChromeUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testChromeHeightPerViewportMode() throws {
    let support = try RemoteBrowserUITestSupport.live()
    let app = support.launch()
    try support.openRemoteTab(app) { _ in }
    let surface = app.descendants(matching: .any)["remote-browser.surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 60), "the remote tab did not attach")
    let takeOver = app.buttons["remote-browser.takeOver"]
    if takeOver.waitForExistence(timeout: 10) { takeOver.tap() }
    XCTAssertTrue(
      app.buttons["remote-browser.handBack"].waitForExistence(timeout: 10),
      "Take Over did not give control")
    support.load(support.page("mobile.html"), in: app)
    Thread.sleep(forTimeInterval: 2)

    for mode in ["keep", "fit", "mobile"] {
      try support.chooseViewport(mode, in: app)
      Thread.sleep(forTimeInterval: 2.5)
      let measured = measure(app, surface: surface)
      print("RBCHROME device=\(Self.device(app)) mode=\(mode) \(measured)")
      let attachment = XCTAttachment(string: "\(mode): \(measured)")
      attachment.lifetime = .keepAlways
      add(attachment)
      try RemoteBrowserUITestSupport.shot("rb-bar-\(Self.device(app))-\(mode)", in: self)
      if Self.device(app) != "ipad" {
        // Safari's layout: the status bar and the address pill, nothing else above the page.
        XCTAssertLessThanOrEqual(
          surface.frame.minY, 130, "the chrome above the page grew back (\(measured))")
      }
    }

    // Scrolling the page down collapses the bars where they collapse (iPhone).
    surface.swipeUp(velocity: .slow)
    Thread.sleep(forTimeInterval: 2.5)
    let collapsed = measure(app, surface: surface)
    print("RBCHROME device=\(Self.device(app)) mode=mobile-scrolled \(collapsed)")
    try RemoteBrowserUITestSupport.shot("rb-bar-\(Self.device(app))-mobile-scrolled", in: self)

    try checkThemeEditingAndMenu(support, app: app)
  }

  /// A page with a coloured top edge tints the bars; editing shows the field and Cancel; the
  /// page menu leads back to the sessions where the navigation bar is hidden (iPhone).
  @MainActor
  private func checkThemeEditingAndMenu(_ support: RemoteBrowserUITestSupport, app: XCUIApplication)
    throws
  {
    support.load(support.page("theme.html"), in: app)
    Thread.sleep(forTimeInterval: 3)
    try RemoteBrowserUITestSupport.shot("rb-bar-\(Self.device(app))-theme", in: self)
    let pill = app.buttons["remote-browser.address"]
    XCTAssertTrue(pill.waitForExistence(timeout: 10), "no address pill after loading")
    pill.tap()
    let cancel = app.buttons["remote-browser.address.cancel"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5), "no Cancel while editing the address")
    try RemoteBrowserUITestSupport.shot("rb-bar-\(Self.device(app))-editing", in: self)
    cancel.tap()
    let menu = app.buttons["remote-browser.menu"]
    XCTAssertTrue(menu.waitForExistence(timeout: 5), "no page menu after Cancel")
    menu.tap()
    Thread.sleep(forTimeInterval: 1)
    try RemoteBrowserUITestSupport.shot("rb-bar-\(Self.device(app))-menu", in: self)

    let sessions = app.buttons.matching(
      NSPredicate(format: "identifier == 'remote-browser.menu.sessions' OR label == 'Sessions'")
    ).firstMatch
    if Self.device(app) != "ipad" {
      XCTAssertTrue(sessions.waitForExistence(timeout: 5), "no Sessions in the page menu")
      sessions.tap()
      let row = app.descendants(matching: .any)["session-row-\(support.sessionID)"].firstMatch
      XCTAssertTrue(row.waitForExistence(timeout: 10), "Sessions did not show the session list")
    }
  }

  /// The surface and bar frames, in points.
  @MainActor
  private func measure(_ app: XCUIApplication, surface: XCUIElement) -> String {
    let window = app.windows.firstMatch.frame
    let page = surface.frame
    var fields = [
      "window=\(Int(window.height))", "surfaceTop=\(Int(page.minY))",
      "surfaceBottom=\(Int(page.maxY))", "surfaceHeight=\(Int(page.height))",
      "chrome=\(Int(window.height - page.height))",
    ]
    let addressBar = app.descendants(matching: .any)["remote-browser.addressBar"]
    let toolbar = app.descendants(matching: .any)["remote-browser.toolbar"]
    if addressBar.exists, toolbar.exists, toolbar.isHittable {
      let top = max(page.minY, addressBar.frame.maxY)
      let bottom = min(page.maxY, toolbar.frame.minY)
      fields.append("addressBarBottom=\(Int(addressBar.frame.maxY))")
      fields.append("toolbarTop=\(Int(toolbar.frame.minY))")
      fields.append("unobscured=\(Int(bottom - top))")
    }
    return fields.joined(separator: " ")
  }

  /// `ipad`, `iphonese` (a home-button phone) or `iphone`.
  @MainActor
  private static func device(_ app: XCUIApplication) -> String {
    if UIDevice.current.userInterfaceIdiom == .pad { return "ipad" }
    return app.windows.firstMatch.frame.height < 700 ? "iphonese" : "iphone"
  }
}
