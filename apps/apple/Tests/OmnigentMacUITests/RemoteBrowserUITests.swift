import AppKit
import XCTest

/// A remote browser tab end to end against a real server, runner and browser host: open one from
/// the new-tab page, load a page, click and type into it, go back, scroll, hand control back and
/// take it again, and use the tab in a split pane.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL`, `OMNIGENT_E2E_REMOTE_SESSION_ID` (a
/// session whose runner has the remote browser on) and `OMNIGENT_E2E_REMOTE_PAGE_URL` (the page
/// in `Tests/Fixtures/remote-browser`, served over HTTP), all with the `TEST_RUNNER_` prefix.
final class RemoteBrowserUITests: XCTestCase {
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
  func testRemoteTabBrowsesClicksAndTypes() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_REMOTE_SESSION_ID"],
      let page = environment["OMNIGENT_E2E_REMOTE_PAGE_URL"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL, _REMOTE_SESSION_ID and _PAGE_URL.")
    }
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-tabs-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path, "-OmnigentRemoteBrowser", "YES",
    ]
    app.launch()
    let window = app.windows.firstMatch

    openRemoteTab(app, window: window, sessionID: sessionID)
    let surface = window.descendants(matching: .any)["remote-browser.surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 60), "the remote tab did not attach")
    takeOverIfOffered(window)
    Thread.sleep(forTimeInterval: 3)
    save(window, "opened")

    try checkBrowsing(app, window: window, surface: surface, page: page)
    try checkScrollAndControl(window, surface: surface)
    try checkSplitPane(app, window: window)
    app.terminate()
  }

  /// Loads the page from the address field, types into it, clicks, follows a link and goes back.
  @MainActor
  private func checkBrowsing(
    _ app: XCUIApplication, window: XCUIElement, surface: XCUIElement, page: String
  ) throws {
    // Load the test page from the address field.
    let address = window.textFields["remote-browser.address"]
    XCTAssertTrue(address.waitForExistence(timeout: 10), "no address field")
    address.click()
    address.typeKey("a", modifierFlags: .command)
    address.typeText(page + "\n")
    XCTAssertTrue(waitForTab(titled: "RB test page", in: window), "the test page did not load")
    Thread.sleep(forTimeInterval: 2)
    save(window, "page")

    // Click the field in the page, type, then click the button.
    click(css: CGPoint(x: 300, y: 70), in: surface)
    Thread.sleep(forTimeInterval: 0.5)
    app.typeText("hello remote")
    Thread.sleep(forTimeInterval: 2)
    save(window, "typed")
    click(css: CGPoint(x: 700, y: 70), in: surface)
    Thread.sleep(forTimeInterval: 2)
    save(window, "clicked")

    // Follow the link, then go back.
    click(css: CGPoint(x: 150, y: 207), in: surface)
    XCTAssertTrue(waitForTab(titled: "RB second page", in: window), "the link was not followed")
    Thread.sleep(forTimeInterval: 1)
    save(window, "second-page")
    let back = window.buttons["remote-browser.back"]
    XCTAssertTrue(back.isEnabled, "Back is not enabled after following a link")
    back.click()
    XCTAssertTrue(waitForTab(titled: "RB test page", in: window), "Back did not return")
    Thread.sleep(forTimeInterval: 2)
    save(window, "back")
  }

  /// Scrolls the page's list, then checks that input reaches the page only while this client
  /// holds control: the toggle box changes colour on a click after Take Over, not after Hand Back.
  @MainActor
  private func checkScrollAndControl(_ window: XCUIElement, surface: XCUIElement) throws {
    coordinate(css: CGPoint(x: 400, y: 500), in: surface).scroll(byDeltaX: 0, deltaY: -400)
    Thread.sleep(forTimeInterval: 2)
    save(window, "scrolled")

    XCTAssertEqual(try boxColor(surface), .green, "the toggle box did not start green")
    let handBack = window.buttons["remote-browser.handBack"]
    XCTAssertTrue(handBack.waitForExistence(timeout: 5), "no Hand Back while in control")
    handBack.click()
    let takeOver = window.buttons["remote-browser.takeOver"]
    XCTAssertTrue(takeOver.waitForExistence(timeout: 10), "no Take Over after handing back")
    click(css: toggleBox, in: surface)
    Thread.sleep(forTimeInterval: 1.5)
    save(window, "agent-owns")
    XCTAssertEqual(try boxColor(surface), .green, "a click reached the page after Hand Back")

    takeOver.click()
    XCTAssertTrue(handBack.waitForExistence(timeout: 10), "no Hand Back after taking over")
    // A take sends no keyframe: the picture must stay up.
    XCTAssertEqual(try boxColor(surface), .green, "the picture changed on Take Over")
    click(css: toggleBox, in: surface)
    XCTAssertTrue(waitForBox(.red, in: surface), "a click after Take Over did not reach the page")
    save(window, "taken-back")
  }

  /// View > Show Split View puts the remote tab beside the chat; it keeps streaming and taking
  /// input at the narrower size.
  @MainActor
  private func checkSplitPane(_ app: XCUIApplication, window: XCUIElement) throws {
    let leading = window.descendants(matching: .any)["tab-pane-leading"]
    let trailing = window.descendants(matching: .any)["tab-pane-trailing"]
    for _ in 0..<3 where !leading.exists {
      menu(app, "View", "Show Split View")
      _ = leading.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(leading.exists && trailing.exists, "no split view")
    let surface = window.descendants(matching: .any)["remote-browser.surface"]
    XCTAssertTrue(surface.waitForExistence(timeout: 10), "the remote tab left the split")
    XCTAssertTrue(
      leading.frame.contains(CGPoint(x: surface.frame.midX, y: surface.frame.midY)),
      "the remote page is not in the left pane")
    Thread.sleep(forTimeInterval: 2)
    XCTAssertEqual(try boxColor(surface), .red, "the split pane lost the picture")
    click(css: toggleBox, in: surface)
    XCTAssertTrue(waitForBox(.green, in: surface), "a click in the split pane did not land")
    save(window, "split")
    menu(app, "View", "Hide Split View")
  }

  /// Opens the session's chat, then a remote browser tab in the default profile from the new-tab
  /// page.
  @MainActor
  private func openRemoteTab(_ app: XCUIApplication, window: XCUIElement, sessionID: String) {
    // The session's chat, so the remote tab belongs to it.
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    row.click()

    // The new-tab page's Remote Browser launcher: this session, default profile.
    app.typeKey("t", modifierFlags: .command)
    let launcher = window.menuButtons["newtab-remote-browser"].firstMatch
    XCTAssertTrue(launcher.waitForExistence(timeout: 20), "the new-tab page has no Remote Browser")
    launcher.click()
    let session = app.menuItems["newtab-remote-browser-\(sessionID)"].firstMatch
    XCTAssertTrue(session.waitForExistence(timeout: 10), "the launcher does not list the session")
    session.hover()
    let profile = app.menuItems["newtab-remote-browser-\(sessionID)-default"].firstMatch
    XCTAssertTrue(profile.waitForExistence(timeout: 10), "no default profile to choose")
    profile.click()
  }

  /// Takes control when the agent holds it.
  @MainActor
  private func takeOverIfOffered(_ window: XCUIElement) {
    let takeOver = window.buttons["remote-browser.takeOver"]
    if takeOver.waitForExistence(timeout: 5) { takeOver.click() }
  }

  /// Waits for a tab whose title starts with `title`.
  @MainActor
  private func waitForTab(titled title: String, in window: XCUIElement) -> Bool {
    let tab = window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'tab-' AND label CONTAINS %@", title)
    ).firstMatch
    return tab.waitForExistence(timeout: 20)
  }

  /// The point of `surface` showing a CSS point of the remote viewport, letterboxed.
  @MainActor
  private func coordinate(css point: CGPoint, in surface: XCUIElement) -> XCUICoordinate {
    let offset = viewOffset(css: point, size: surface.frame.size)
    return surface.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: offset.x, dy: offset.y))
  }

  @MainActor
  private func click(css point: CGPoint, in surface: XCUIElement) {
    coordinate(css: point, in: surface).click()
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
    let image = surface.screenshot().image
    let bitmap = try XCTUnwrap(
      image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
    let pixelScale = CGFloat(bitmap.pixelsWide) / surface.frame.width
    let point = viewOffset(css: toggleBox, size: surface.frame.size)
    let color = try XCTUnwrap(
      bitmap.colorAt(x: Int(point.x * pixelScale), y: Int(point.y * pixelScale))?.usingColorSpace(
        .sRGB))
    if color.greenComponent > color.redComponent + 0.2 { return .green }
    if color.redComponent > color.greenComponent + 0.2 { return .red }
    return .other
  }

  @MainActor
  private func waitForBox(_ expected: BoxColor, in surface: XCUIElement) -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if (try? boxColor(surface)) == expected { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return false
  }

  @MainActor
  private func menu(_ app: XCUIApplication, _ menu: String, _ item: String) {
    app.menuBars.menuBarItems[menu].click()
    let entry = app.menuBars.menuItems[item]
    XCTAssertTrue(entry.waitForExistence(timeout: 5), "no \(menu) > \(item)")
    entry.click()
    // A click that did not land leaves the menu open.
    if entry.isHittable { app.typeKey(.escape, modifierFlags: []) }
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-remote-browser-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
