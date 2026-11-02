import UIKit
import XCTest

/// Shared steps of the remote browser touch UI tests: the live environment, opening a remote
/// tab, mapping the fixture page's CSS points onto the surface, and reading the decoded video's
/// colours.
@MainActor
struct RemoteBrowserUITestSupport {
  /// The colour class of a pixel of the decoded video.
  enum PixelColor { case green, red, other }

  /// The fixture's box that toggles between green and red on every mouse down (CSS px).
  static let toggleBox = CGPoint(x: 1050, y: 190)

  /// The server, session and fixture page the tests run against.
  let server: String
  let sessionID: String
  let page: String
  /// The remote viewport the CSS-to-surface mapping assumes (the host's default).
  var viewport = CGSize(width: 1280, height: 800)

  /// The environment's live host, or a skip when it is not configured.
  /// - Returns: The support for it.
  /// - Throws: `XCTSkip`.
  static func live() throws -> Self {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_REMOTE_SESSION_ID"],
      let page = environment["OMNIGENT_E2E_REMOTE_PAGE_URL"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL, _REMOTE_SESSION_ID and _PAGE_URL.")
    }
    return Self(server: server, sessionID: sessionID, page: page)
  }

  /// Another fixture page beside the configured one.
  /// - Parameter name: Its file name.
  /// - Returns: Its URL.
  func page(_ name: String) -> String {
    URL(string: page)?.deletingLastPathComponent().appendingPathComponent(name).absoluteString
      ?? page
  }

  /// Launches the app against the live server with the remote browser on, in Keep Remote Size
  /// (the mode is saved per device, so an earlier test's choice would otherwise carry over).
  /// - Returns: The app.
  func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-OmnigentRemoteBrowser", "YES",
      "-remoteBrowser.viewportMode", #"{"keep":{}}"#,
    ]
    app.launch()
    return app
  }

  /// The new-tab page's Remote Browser launcher: this session, default profile.
  /// - Parameters:
  ///   - app: The app.
  ///   - shot: Records a step.
  /// - Throws: A failed screenshot write.
  func openRemoteTab(_ app: XCUIApplication, shot: (String) throws -> Void) throws {
    let launcher = app.buttons["newtab-remote-browser"].firstMatch
    if !launcher.waitForExistence(timeout: 20) {
      openNewTab(app)
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

  /// A new tab: the tab strip's + where there is a strip (iPad), else the session's tab
  /// switcher and its New Tab (iPhone).
  private func openNewTab(_ app: XCUIApplication) {
    let newTab = app.buttons["tab-new"].firstMatch
    if newTab.exists {
      newTab.tap()
      return
    }
    // A relaunch can restore a tab, where the switcher is already in the toolbar.
    let switcher = app.buttons["tab-switcher"].firstMatch
    if !switcher.waitForExistence(timeout: 5) {
      let row = app.descendants(matching: .any)["session-row-\(sessionID)"].firstMatch
      XCTAssertTrue(
        row.waitForExistence(timeout: 20), "the session list does not show the session")
      row.tap()
    }
    XCTAssertTrue(switcher.waitForExistence(timeout: 20), "no tab switcher in the session")
    switcher.tap()
    let overviewNew = app.buttons["tab-overview-new"].firstMatch
    XCTAssertTrue(overviewNew.waitForExistence(timeout: 10), "no New Tab in the tab overview")
    overviewNew.tap()
  }

  /// Types a URL into the remote tab's address field.
  /// - Parameters:
  ///   - url: The URL.
  ///   - app: The app.
  func load(_ url: String, in app: XCUIApplication) {
    let address = app.textFields["remote-browser.address"]
    XCTAssertTrue(address.waitForExistence(timeout: 10), "no address field")
    address.tap()
    // The field shows the current page's URL: select it all so the typing replaces it.
    let existing = (address.value as? String) ?? ""
    if !existing.isEmpty, existing != address.placeholderValue {
      address.press(forDuration: 1.0)
      let item = app.menuItems["Select All"]
      let button = app.buttons["Select All"]
      let deadline = Date().addingTimeInterval(5)
      while Date() < deadline, !item.exists, !button.exists {
        Thread.sleep(forTimeInterval: 0.1)
      }
      XCTAssertTrue(item.exists || button.exists, "no Select All for the address")
      (item.exists ? item : button).tap()
    }
    address.typeText(url + "\n")
  }

  /// The point of `surface` showing a CSS point of the remote viewport, letterboxed.
  func coordinate(css point: CGPoint, in surface: XCUIElement) -> XCUICoordinate {
    let offset = viewOffset(css: point, size: surface.frame.size)
    return surface.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: offset.x, dy: offset.y))
  }

  /// A CSS point's position in a surface of `size`, letterboxed.
  func viewOffset(css point: CGPoint, size: CGSize) -> CGPoint {
    let scale = min(size.width / viewport.width, size.height / viewport.height)
    let originX = (size.width - viewport.width * scale) / 2
    let originY = (size.height - viewport.height * scale) / 2
    return CGPoint(x: originX + point.x * scale, y: originY + point.y * scale)
  }

  /// The toggle box's colour in a screenshot of the decoded video.
  func boxColor(_ surface: XCUIElement) throws -> PixelColor {
    try color(atView: viewOffset(css: Self.toggleBox, size: surface.frame.size), in: surface)
  }

  /// The colour class of the decoded video at a point of `surface` (view points).
  func color(atView point: CGPoint, in surface: XCUIElement) throws -> PixelColor {
    let image = try XCTUnwrap(surface.screenshot().image.cgImage)
    let pixelScale = CGFloat(image.width) / surface.frame.width
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

  /// Waits for the toggle box to show `expected`.
  func waitForBox(_ expected: PixelColor, in surface: XCUIElement, timeout: TimeInterval = 5)
    -> Bool
  {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if (try? boxColor(surface)) == expected { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return false
  }

  /// The page's state report from its title (the v1.1 fixture pages), e.g. `w=390 dpr=3 sy=0`.
  func report(_ surface: XCUIElement) -> [String: String] {
    let title = (surface.value as? String) ?? ""
    var fields: [String: String] = [:]
    for word in title.split(separator: " ") {
      let parts = word.split(separator: "=", maxSplits: 1)
      if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
    }
    if let range = title.range(of: "value=") {
      fields["value"] = String(title[range.upperBound...])
    }
    return fields
  }

  /// Waits until the page's report satisfies `condition`, else fails with what it reported.
  func waitFor(
    _ what: String, in surface: XCUIElement, timeout: TimeInterval = 15,
    _ condition: ([String: String]) -> Bool
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition(report(surface)) { return }
      Thread.sleep(forTimeInterval: 0.2)
    }
    XCTFail("\(what); the page reports \(String(describing: surface.value))")
  }

  /// Writes a screenshot to `OMNIGENT_E2E_SHOTS_DIR` and attaches it to `test`.
  /// - Parameters:
  ///   - name: The file name without `.png`.
  ///   - test: The running test.
  /// - Throws: A failed write.
  static func shot(_ name: String, in test: XCTestCase) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["OMNIGENT_E2E_SHOTS_DIR"] else {
      return
    }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
  }
}
