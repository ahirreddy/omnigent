import AppKit
import XCTest

/// "Fork chat from here" end to end against a running server: hover an assistant message, fork
/// from it with Clone, and check that the fork opens as a new chat tab holding the transcript up
/// to that message.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_FORK_SESSION_ID` (a
/// session with at least two assistant messages; pass them with the `TEST_RUNNER_` prefix to
/// `xcodebuild test`). Screenshots are attached to the result bundle.
final class ForkChatUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testForkFromMessageOpensTheForkInANewTab() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_FORK_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _FORK_SESSION_ID to run.")
    }
    let app = launch(server: server)
    defer { app.terminate() }
    let window = app.windows.firstMatch
    open(sessionID, in: app)

    let answers = answerTexts(window)
    let loaded = NSPredicate(format: "count >= 2")
    expectation(for: loaded, evaluatedWith: answers)
    waitForExpectations(timeout: 30)
    let first = answers.element(boundBy: 0)
    let firstText = text(of: first)
    let rowID = first.identifier.replacingOccurrences(of: "message-text-", with: "")
    let sourceCount = answers.count
    save(window, "source")

    // The row is hidden until the pointer is over the message.
    first.hover()
    let fork = window.buttons["message-fork-\(rowID)"]
    XCTAssertTrue(fork.waitForExistence(timeout: 10), "no Fork button on \(rowID)")
    XCTAssertTrue(window.buttons["message-copy-\(rowID)"].exists, "no Copy beside Fork")
    save(window, "hover")
    fork.click()

    // On macOS the sheet's own identifier does not reach the Sheet element.
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "the fork sheet did not open")
    save(window, "sheet")
    let clone = app.buttons["fork-clone"]
    XCTAssertTrue(clone.waitForExistence(timeout: 10))
    let chatTabs = window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'tab-chat-'"))
    let tabsBefore = chatTabs.count
    clone.click()

    expectation(for: NSPredicate(format: "count == %d", tabsBefore + 1), evaluatedWith: chatTabs)
    waitForExpectations(timeout: 30)
    XCTAssertFalse(sheet.exists, "the sheet stayed open")

    // The fork's tab is focused and holds the transcript up to the forked message.
    let forkAnswers = answerTexts(window)
    expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: forkAnswers)
    waitForExpectations(timeout: 30)
    // Forked items keep their ids, so the focused tab's title tells the fork apart.
    let focused = chatTabs.matching(NSPredicate(format: "isSelected == true")).firstMatch
    XCTAssertTrue(focused.label.hasPrefix("Fork of"), "focused tab: \(focused.label)")
    XCTAssertEqual(text(of: forkAnswers.element(boundBy: 0)), firstText)
    XCTAssertGreaterThan(sourceCount, forkAnswers.count)
    Thread.sleep(forTimeInterval: 1)
    save(window, "forked")
  }

  /// Launches the app on `server` with its own tab store.
  @MainActor
  private func launch(server: String) -> XCUIApplication {
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-fork-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    return app
  }

  /// Opens `sessionID` from the sidebar and waits for its composer.
  @MainActor
  private func open(_ sessionID: String, in app: XCUIApplication) {
    let window = app.windows.firstMatch
    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      window.click()
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")
  }

  @MainActor
  private func answerTexts(_ window: XCUIElement) -> XCUIElementQuery {
    window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'message-text-'"))
  }

  @MainActor
  private func text(of element: XCUIElement) -> String {
    element.label + String(describing: element.value ?? "")
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "mac-fork-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
