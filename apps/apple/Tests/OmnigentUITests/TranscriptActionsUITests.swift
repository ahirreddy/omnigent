import XCTest

/// Transcript actions on touch against the seeded fixture session (see
/// `LiveServerUITestSupport`): Copy link confirms with a banner in both styles, a CLI tool line's
/// actions show its output, and the iPhone title menu switches to Terminal and opens the right
/// panel's tabs.
final class TranscriptActionsUITests: XCTestCase {
  @MainActor
  func testCopyLinkShowsTheBannerInBothStyles() throws {
    let support = LiveServerUITestSupport(self)
    let sessionID = try support.fixtureSession()
    for style in ["chat", "cli"] {
      let app = support.launch(opening: sessionID, extra: ["-omnigent:transcript-style", style])
      support.waitForTranscript(sessionID, in: app)
      support.tap(support.element(prefix: "message-link-", in: app), "\(style): Copy link")
      let banner = support.element("transient-banner", in: app)
      XCTAssertTrue(banner.waitForExistence(timeout: 5), "\(style): no Link copied banner")
      XCTAssertTrue(banner.label.contains("Link copied"), "\(style): banner says \(banner.label)")
      support.shot("\(style)-copy-link")
      app.terminate()
    }
  }

  @MainActor
  func testCLIToolActionsShowTheOutput() throws {
    let support = LiveServerUITestSupport(self)
    let sessionID = try support.fixtureSession()
    let app = support.launch(opening: sessionID, extra: ["-omnigent:transcript-style", "cli"])
    support.waitForTranscript(sessionID, in: app)
    let fold = support.element(prefix: "worked-fold-", in: app)
    let actions = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'tool-toggle-' AND identifier ENDSWITH '-more'")
    ).firstMatch
    if !actions.waitForExistence(timeout: 5), fold.exists { fold.tap() }
    support.tap(actions, "the tool line's actions")
    XCTAssertTrue(app.buttons["Copy input"].waitForExistence(timeout: 5), "no Copy input")
    XCTAssertTrue(app.buttons["Copy output"].exists, "no Copy output")
    support.shot("cli-tool-actions")
    support.tap(app.buttons["Show output"], "Show output")
    let output = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'guide.md'"))
      .firstMatch
    XCTAssertTrue(output.waitForExistence(timeout: 5), "Show output showed nothing")
    support.shot("cli-tool-output")
  }

  @MainActor
  func testPhoneTitleMenuSwitchesViewAndOpensPanelTabs() throws {
    let support = LiveServerUITestSupport(self)
    guard support.isPhone else { throw XCTSkip("iPhone title menu only") }
    let sessionID = try support.fixtureSession()
    let app = support.launch(opening: sessionID)
    support.waitForTranscript(sessionID, in: app)

    openTitleMenu(support, app)
    support.shot("title-menu")
    support.tap(app.buttons["Terminal"], "Terminal in the title menu")
    let terminal = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier IN {'session-terminal', 'terminal-offline', 'terminal-starting'}")
    ).firstMatch
    XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Terminal did not show the terminal")
    openTitleMenu(support, app)
    support.tap(app.buttons["Chat"], "Chat in the title menu")
    support.waitForTranscript(sessionID, in: app)

    openTitleMenu(support, app)
    support.tap(filesItem(app), "Files in the title menu")
    XCTAssertTrue(
      app.staticTexts["README.md"].waitForExistence(timeout: 15), "Files did not open the panel")
    support.shot("title-menu-files")
  }

  /// Opens the navigation bar's title menu.
  @MainActor
  private func openTitleMenu(_ support: LiveServerUITestSupport, _ app: XCUIApplication) {
    let title = app.navigationBars.firstMatch.buttons["UI test fixture"]
    let target = title.exists ? title : app.navigationBars.firstMatch.staticTexts["UI test fixture"]
    support.tap(target, "the title")
    XCTAssertTrue(filesItem(app).waitForExistence(timeout: 5), "the title menu did not open")
  }

  /// The menu's Files item, labeled with its count; iOS menu items carry no identifiers.
  @MainActor
  private func filesItem(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Files'")).firstMatch
  }
}
