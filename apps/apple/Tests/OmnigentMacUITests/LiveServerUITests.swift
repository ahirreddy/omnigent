import AppKit
import XCTest

/// End-to-end check against a running Omnigent server. Skipped unless the runner gets
/// `OMNIGENT_LIVE_SERVER_URL` (pass `TEST_RUNNER_OMNIGENT_LIVE_SERVER_URL=http://127.0.0.1:6767`
/// to `xcodebuild test`). Each step attaches a screenshot to the result bundle; export them with
/// `xcrun xcresulttool export attachments --path <bundle> --output-path <dir>` (the sandboxed
/// test runner cannot write outside its container).
///
/// Covers: connecting a window, New Window, the Settings engine picker, and the Browser window
/// loading the server with the default engine. `omnigent://` routing is checked by hand with
/// `open -a <built app> omnigent://<host:port>/c/<id>`: `XCUIApplication.open(_:)` did not
/// deliver the URL to `application(_:open:)` in local runs.
final class LiveServerUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testLiveServerFlow() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_LIVE_SERVER_URL"],
      let serverURL = URL(string: server), let host = serverURL.host(), let port = serverURL.port
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_LIVE_SERVER_URL to run against a live server.")
    }
    #if OMNIGENT_CHROMIUM
      let edition = "devid"
      let defaultEngine = "Chromium"
    #else
      let edition = "appstore"
      let defaultEngine = "System (WebKit)"
    #endif

    let app = XCUIApplication()
    // Argument-domain defaults: new windows open on the server; skip restored windows.
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()

    let serverName = app.descendants(matching: .any)["sidebar"]
    XCTAssertTrue(serverName.waitForExistence(timeout: 20), "window did not connect to \(server)")
    save(app.windows.firstMatch, "\(edition)-connected")

    let before = app.windows.count
    app.typeKey("n", modifierFlags: [.command, .shift])
    expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: app.windows)
    waitForExpectations(timeout: 10)
    save(app.windows.firstMatch, "\(edition)-new-window")

    app.typeKey(",", modifierFlags: .command)
    let picker = app.popUpButtons["settings.browserEngine"]
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    XCTAssertEqual(picker.value as? String, defaultEngine)
    picker.click()
    XCTAssertTrue(app.menuItems["System (WebKit)"].waitForExistence(timeout: 5))
    save(picker, "\(edition)-settings", screen: true, margin: CGSize(width: 340, height: 160))
    app.typeKey(.escape, modifierFlags: [])
    app.typeKey("w", modifierFlags: .command)

    checkBrowserWindow(app, edition: edition, host: host, port: port, engine: defaultEngine)
  }

  /// Option-Command-B opens the Browser window, which loads the server with the default engine.
  @MainActor
  private func checkBrowserWindow(
    _ app: XCUIApplication, edition: String, host: String, port: Int, engine defaultEngine: String
  ) {
    app.windows.firstMatch.click()
    app.typeKey("b", modifierFlags: [.command, .option])
    let browser = app.windows.matching(
      NSPredicate(format: "title BEGINSWITH %@", "Browser")
    ).firstMatch
    XCTAssertTrue(browser.waitForExistence(timeout: 20), "Browser window did not open")
    let address = browser.textFields["browser.address"]
    XCTAssertTrue(address.waitForExistence(timeout: 20))
    let loaded = NSPredicate(format: "value CONTAINS %@", "\(host):\(port)")
    expectation(for: loaded, evaluatedWith: address)
    waitForExpectations(timeout: 30)
    let engine = browser.descendants(matching: .any)["browser.enginePicker"]
    XCTAssertTrue(engine.exists)
    XCTAssertTrue(
      [engine.label, engine.value as? String ?? "", engine.title].contains(defaultEngine),
      "engine picker shows \(engine.label) / \(String(describing: engine.value))")
    // Give the page time to paint before the screenshot.
    Thread.sleep(forTimeInterval: 4)
    save(browser, "\(edition)-browser")
  }

  /// Attaches a screenshot of `element`. `screen` captures the screen (to include open menus)
  /// cropped to the element's frame plus `margin`, so other apps' windows are not recorded.
  @MainActor
  private func save(
    _ element: XCUIElement, _ name: String, screen: Bool = false,
    margin: CGSize = CGSize(width: 24, height: 24)
  ) {
    let attachment: XCTAttachment
    if screen {
      let shot = XCUIScreen.main.screenshot().image
      let frame = element.frame.insetBy(dx: -margin.width, dy: -margin.height)
      guard let cropped = Self.crop(shot, to: frame) else {
        XCTFail("Could not crop the screen capture to \(frame)")
        return
      }
      attachment = XCTAttachment(image: cropped)
    } else {
      attachment = XCTAttachment(screenshot: element.screenshot())
    }
    attachment.name = "mac-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  @MainActor
  private static func crop(_ image: NSImage, to frame: CGRect) -> NSImage? {
    // `forProposedRect` takes a pointer; nil asks for the whole image.
    // XCUI frames are in screen points; the capture is in pixels of the main display.
    guard let cgImage = unsafe image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let screenWidth = NSScreen.main?.frame.width, screenWidth > 0
    else { return nil }
    let scale = CGFloat(cgImage.width) / screenWidth
    let pixels = CGRect(
      x: frame.minX * scale, y: frame.minY * scale,
      width: frame.width * scale, height: frame.height * scale
    ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
    guard !pixels.isEmpty, let cropped = cgImage.cropping(to: pixels) else { return nil }
    return NSImage(cgImage: cropped, size: NSSize(width: pixels.width, height: pixels.height))
  }
}
