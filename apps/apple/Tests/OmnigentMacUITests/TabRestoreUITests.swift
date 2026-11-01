import AppKit
import XCTest

/// Tabs survive quitting: open a session's chat, a terminal tab and a browser tab, quit, relaunch
/// and check the strip comes back with the same kinds, the browser tab selected.
///
/// Runs against the same server as ``NativeAppE2EUITests`` and is skipped unless the runner gets
/// `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_E2E_SESSION_ID` (with the `TEST_RUNNER_` prefix). Tabs
/// are saved in a scratch directory (`-OmnigentTabsDirectory`), never the user's.
final class TabRestoreUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testTabsRestoreAfterRelaunch() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_E2E_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _SESSION_ID to run.")
    }
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-tabs-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    let window = app.windows.firstMatch

    try openTabs(app, window: window, sessionID: sessionID)
    let kinds = tabKinds(window)

    // Quit (which saves), then relaunch.
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "the app did not quit")
    app.launch()
    let restored = app.windows.firstMatch
    XCTAssertTrue(
      tab("browser", in: restored).waitForExistence(timeout: 40), "the browser tab did not restore")
    XCTAssertTrue(terminalTab(in: restored).exists, "the terminal tab did not restore")
    XCTAssertTrue(tab("chat", in: restored).exists, "the chat tab did not restore")
    XCTAssertEqual(tabKinds(restored), kinds, "the strip came back in a different order")
    let selected = tab("browser", in: restored)
    XCTAssertTrue(selected.isSelected, "the browser tab was selected when the app quit")
    Thread.sleep(forTimeInterval: 3)
    save(restored, "restored")

    // The restored terminal reattaches when selected (lazy restore).
    terminalTab(in: restored).click()
    let surface = restored.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == 'terminal-tab' OR identifier == 'harness-tab'")
    ).firstMatch
    XCTAssertTrue(surface.waitForExistence(timeout: 20), "the terminal tab did not build")
    save(restored, "restored-terminal")
    app.terminate()
  }

  /// Opens a session's chat (from the sidebar), a terminal tab (Control-`) and a browser tab
  /// (Option-Command-B).
  @MainActor
  private func openTabs(_ app: XCUIApplication, window: XCUIElement, sessionID: String) throws {
    // A session's chat tab, from the sidebar.
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      window.click()
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")
    XCTAssertTrue(tab("chat", in: window).waitForExistence(timeout: 10), "no chat tab")

    // A terminal tab: Control-` shows the session's terminal, starting a shell if it has none.
    app.typeKey("`", modifierFlags: .control)
    let terminal = window.descendants(matching: .any).matching(
      NSPredicate(
        format:
          "identifier BEGINSWITH 'tab-terminal-' OR identifier BEGINSWITH 'tab-agentTerminal-'")
    ).firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 30), "no terminal tab opened")
    save(window, "terminal")

    // A browser tab: Option-Command-B.
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(tab("browser", in: window).waitForExistence(timeout: 20), "no browser tab")
    Thread.sleep(forTimeInterval: 3)
    save(window, "before-quit")
  }

  @MainActor
  private func tab(_ kind: String, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "tab-\(kind)-")
    ).firstMatch
  }

  @MainActor
  private func terminalTab(in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(
      NSPredicate(
        format:
          "identifier BEGINSWITH 'tab-terminal-' OR identifier BEGINSWITH 'tab-agentTerminal-'")
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
    attachment.name = "e2e-tabs-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
