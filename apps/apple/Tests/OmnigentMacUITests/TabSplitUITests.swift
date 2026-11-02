import AppKit
import XCTest

/// The tab split view against a live server: a session's chat and a browser tab side by side
/// (View > Show Split View, Command-\), both panes on screen with their own strip sections, pane
/// focus with Option-Command-Arrow, and back to one pane. Also checks the primary chat has no
/// close button and File > Close Tab is disabled on it. Screenshots are `e2e-split-<step>`.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_E2E_SESSION_ID` (with
/// the `TEST_RUNNER_` prefix). Tabs are saved in a scratch directory, never the user's.
final class TabSplitUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testChatAndBrowserSideBySide() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _SESSION_ID to run.")
    }
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-split-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    defer { app.terminate() }
    let window = app.windows.firstMatch

    let input = try openChat(app, window: window, sessionID: sessionID)
    try checkSplit(app, window: window, input: input)
  }

  /// The session's chat, from the sidebar: its primary chat, which has no close button.
  @MainActor
  private func openChat(_ app: XCUIApplication, window: XCUIElement, sessionID: String) throws
    -> XCUIElement
  {
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")
    let chat = tab("chat", in: window)
    XCTAssertTrue(chat.waitForExistence(timeout: 10), "no chat tab")
    // The selected tab always shows its close button when it has one, so no hover is needed.
    let chatID = String(chat.identifier.dropFirst("tab-chat-".count))
    XCTAssertFalse(
      window.descendants(matching: .any)["tab-close-\(chatID)"].exists,
      "the primary chat shows a close button")
    XCTAssertFalse(app.menuItems["Close Tab"].isEnabled, "Close Tab is enabled on the chat")
    return input
  }

  /// A browser tab, then View > Show Split View: the browser stays left, the chat goes right.
  @MainActor
  private func checkSplit(_ app: XCUIApplication, window: XCUIElement, input: XCUIElement) throws {
    let chat = tab("chat", in: window)
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(tab("browser", in: window).waitForExistence(timeout: 20), "no browser tab")
    // From the menu: a focused page gets key equivalents first, as in Chromium.
    let leading = window.descendants(matching: .any)["tab-pane-leading"]
    let trailing = window.descendants(matching: .any)["tab-pane-trailing"]
    for _ in 0..<3 where !leading.exists {
      menu(app, "View", "Show Split View")
      _ = leading.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(leading.exists, "no left pane")
    XCTAssertTrue(trailing.exists, "no right pane")
    XCTAssertLessThan(leading.frame.maxX, trailing.frame.minX + 2, "the panes overlap")
    XCTAssertGreaterThan(trailing.frame.width, 300, "the right pane is too narrow")
    XCTAssertTrue(input.waitForExistence(timeout: 10), "the chat is not on screen beside the page")
    XCTAssertTrue(
      trailing.frame.contains(CGPoint(x: input.frame.midX, y: input.frame.midY)),
      "the chat's composer is not in the right pane")
    let sections = (
      leading: window.descendants(matching: .any)["tab-section-leading"],
      trailing: window.descendants(matching: .any)["tab-section-trailing"]
    )
    XCTAssertTrue(sections.leading.exists && sections.trailing.exists, "no strip section per pane")
    XCTAssertTrue(
      sections.trailing.frame.contains(CGPoint(x: chat.frame.midX, y: chat.frame.midY)),
      "the chat tab is not over its pane")
    XCTAssertTrue(isFocused(leading), "the browser's pane lost focus")
    Thread.sleep(forTimeInterval: 3)
    save(window, "both-panes")

    try checkFocus(app, window: window)
  }

  /// View > Focus Right Pane focuses the chat's pane, where Close Tab stays disabled;
  /// Option-Command-Left Arrow from the chat's composer focuses the page again.
  @MainActor
  private func checkFocus(_ app: XCUIApplication, window: XCUIElement) throws {
    let leading = window.descendants(matching: .any)["tab-pane-leading"]
    let trailing = window.descendants(matching: .any)["tab-pane-trailing"]
    menu(app, "View", "Focus Right Pane")
    XCTAssertTrue(waitForFocus(trailing), "the right pane did not take focus")
    XCTAssertFalse(app.menuItems["Close Tab"].isEnabled, "Close Tab is enabled on the chat")
    app.textViews["composer-input"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .click()
    app.typeKey(.leftArrow, modifierFlags: [.command, .option])
    XCTAssertTrue(waitForFocus(leading), "the left pane did not take focus back")
    save(window, "focus")

    // Back to one pane.
    menu(app, "View", "Hide Split View")
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: trailing)
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "the split did not close")
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
  private func tab(_ kind: String, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "tab-\(kind)-")
    ).firstMatch
  }

  /// The pane's marker reads "<side> pane, focused" while it has focus.
  @MainActor
  private func isFocused(_ pane: XCUIElement) -> Bool {
    pane.label.hasSuffix("focused")
  }

  @MainActor
  private func waitForFocus(_ pane: XCUIElement) -> Bool {
    let predicate = NSPredicate(format: "label ENDSWITH 'focused'")
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: pane)
    return XCTWaiter.wait(for: [expectation], timeout: 10) == .completed
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "e2e-split-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
