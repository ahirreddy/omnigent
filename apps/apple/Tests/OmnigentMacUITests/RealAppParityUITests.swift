import AppKit
import XCTest

/// The real app's window chrome, against a live server: the tab strip shares the titlebar row,
/// dragging a tab reorders it without moving the window, the strip's empty space drags the
/// window, and the server reads "This Mac" rather than its loopback address. Screenshots in
/// light and dark are attached as `e2e-<appearance>-<step>`.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_PARITY_SESSION_ID`
/// (a session whose agent declares a terminal), with the `TEST_RUNNER_` prefix. Tabs are saved
/// in a scratch directory, never the user's.
final class RealAppParityUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testTitlebarTabsLight() throws {
    try run(appearance: "light")
  }

  @MainActor
  func testTitlebarTabsDark() throws {
    try run(appearance: "dark")
  }

  @MainActor
  private func run(appearance: String) throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_PARITY_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _PARITY_SESSION_ID to run.")
    }
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-parity-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path, "-web-theme", appearance,
    ]
    app.launch()
    defer { app.terminate() }
    let window = app.windows.firstMatch

    // The session's chat tab, from the sidebar.
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")

    // The loopback server is "This Mac" in the sidebar's server switcher.
    let switcher = window.descendants(matching: .any)["server-switcher"]
    XCTAssertTrue(switcher.waitForExistence(timeout: 10))
    XCTAssertFalse(switcher.label.contains("127.0.0.1"), "switcher: \(switcher.label)")

    // A terminal tab (Control-`) and a browser tab (Option-Command-B), then back to the chat.
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(
      tab(["terminal", "agentTerminal"], in: window).waitForExistence(timeout: 30),
      "no terminal tab opened")
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(tab(["browser"], in: window).waitForExistence(timeout: 20), "no browser tab")
    Thread.sleep(forTimeInterval: 3)
    save(window, "\(appearance)-browser")
    // In a browser tab Command-R is the page's Reload; Reconnect has its own shortcut.
    XCTAssertTrue(app.menuItems["Reload Page"].isEnabled, "Browser > Reload Page is disabled")
    let chat = tab(["chat"], in: window)
    chat.click()
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the chat tab did not come back")
    Thread.sleep(forTimeInterval: 2)
    save(window, "\(appearance)-chat")

    // The tab strip shares the titlebar row with the trailing toolbar items.
    let strip = window.descendants(matching: .any)["tab-strip"]
    let inspector = window.descendants(matching: .any)["toggle-inspector"]
    XCTAssertTrue(strip.exists && inspector.exists)
    XCTAssertLessThan(
      abs(strip.frame.midY - inspector.frame.midY), 8,
      "strip \(strip.frame) and toolbar \(inspector.frame) are on different rows")
    XCTAssertLessThan(strip.frame.minY - window.frame.minY, 40, "the strip is below the titlebar")

    try checkDragging(window: window, strip: strip, chat: chat)
  }

  /// A tab drag moves the tab, not the window; a drag on the strip's empty space moves the
  /// window.
  @MainActor
  private func checkDragging(window: XCUIElement, strip: XCUIElement, chat: XCUIElement) throws {
    let before = window.frame
    let kinds = tabKinds(window)
    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(
      forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: chat.frame.width * 1.2, dy: 0)))
    Thread.sleep(forTimeInterval: 1)
    XCTAssertEqual(window.frame.origin, before.origin, "dragging a tab moved the window")
    XCTAssertNotEqual(tabKinds(window), kinds, "dragging the chat tab did not reorder it")

    // Empty strip space: left of New Tab and the overview menu.
    let empty = strip.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
      .withOffset(CGVector(dx: -90, dy: 0))
    empty.press(forDuration: 0.3, thenDragTo: empty.withOffset(CGVector(dx: -60, dy: 40)))
    Thread.sleep(forTimeInterval: 1)
    XCTAssertNotEqual(window.frame.origin, before.origin, "the strip's empty space did not drag")
  }

  @MainActor
  private func tab(_ kinds: [String], in window: XCUIElement) -> XCUIElement {
    let predicates = kinds.map { NSPredicate(format: "identifier BEGINSWITH %@", "tab-\($0)-") }
    return window.descendants(matching: .any).matching(
      NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
    ).firstMatch
  }

  /// The strip's tab kinds, left to right.
  @MainActor
  private func tabKinds(_ window: XCUIElement) -> [String] {
    window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'tab-' AND NOT identifier BEGINSWITH 'tab-close-'")
    ).allElementsBoundByIndex
      .filter { element in
        let parts = element.identifier.split(separator: "-")
        return parts.count > 2
          && ["chat", "terminal", "agentTerminal", "browser", "newTab"].contains(String(parts[1]))
      }
      .sorted { $0.frame.minX < $1.frame.minX }
      .map { String($0.identifier.split(separator: "-")[1]) }
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
