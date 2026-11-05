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
      // The banner is a container; its message is a child.
      let message = banner.descendants(matching: .any)
        .matching(NSPredicate(format: "label == 'Link copied'")).firstMatch
      XCTAssertTrue(message.exists, "\(style): the banner does not say Link copied")
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
    // Chat and Terminal lead the menu only for a session that offers a terminal.
    if app.buttons["Terminal"].exists {
      app.buttons["Terminal"].tap()
      let terminal = app.descendants(matching: .any).matching(
        NSPredicate(
          format: "identifier IN {'session-terminal', 'terminal-offline', 'terminal-starting'}")
      ).firstMatch
      XCTAssertTrue(terminal.waitForExistence(timeout: 10), "Terminal did not show the terminal")
      openTitleMenu(support, app)
      support.tap(app.buttons["Chat"], "Chat in the title menu")
      support.waitForTranscript(sessionID, in: app)
      openTitleMenu(support, app)
    }
    support.tap(filesItem(app), "Files in the title menu")
    XCTAssertTrue(
      app.descendants(matching: .any)["README.md"].firstMatch.waitForExistence(timeout: 15),
      "Files did not open the panel")
    support.shot("title-menu-files")
  }

  /// Opens the navigation bar's title menu.
  @MainActor
  private func openTitleMenu(_ support: LiveServerUITestSupport, _ app: XCUIApplication) {
    // A button once the menu is attached, plain text before.
    let title = app.navigationBars.firstMatch.descendants(matching: .any)
      .matching(NSPredicate(format: "label == 'UI test fixture'")).firstMatch
    support.tap(title, "the title", timeout: 20)
    XCTAssertTrue(filesItem(app).waitForExistence(timeout: 5), "the title menu did not open")
  }

  /// The menu's Files item, labeled with its count; iOS menu items carry no identifiers.
  @MainActor
  private func filesItem(_ app: XCUIApplication) -> XCUIElement {
    app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Files'")).firstMatch
  }
}
