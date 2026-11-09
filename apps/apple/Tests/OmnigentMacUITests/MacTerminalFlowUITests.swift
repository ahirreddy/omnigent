import XCTest

/// Terminal tabs on the local server's fixture session. The surface is not readable through
/// accessibility, so a command proves itself by writing a file (see `testTerminalTabRunsACommand`).
final class MacTerminalFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// The New Tab page's Terminal launcher opens a shell in the page's session.
  @MainActor
  func testNewTabPageOpensATerminal() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    app.typeKey("t", modifierFlags: .command)

    live.click(live.element("newtab-terminal", in: app), "the Terminal launcher")
    // Several declared terminals are a menu; one, or none known yet, starts at once.
    let choice = app.menuItems.matching(
      NSPredicate(format: "identifier BEGINSWITH 'newtab-terminal-'")
    ).firstMatch
    if choice.waitForExistence(timeout: 3) { choice.click() }
    XCTAssertTrue(
      live.tabs("terminal", in: app).firstMatch.waitForExistence(timeout: 30), "no terminal tab")
    XCTAssertTrue(live.element("terminal-tab", in: app).waitForExistence(timeout: 30))
  }

  /// Command-T in a focused terminal is the app's, not the shell's: a New Tab page opens.
  @MainActor
  func testCommandTOpensATabFromATerminal() throws {
    let live = MacLiveUITestSupport(self)
    let app = try openShell(live)
    defer { app.terminate() }

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      live.element("newtab-page", in: app).waitForExistence(timeout: 10),
      "Command-T stayed in the terminal")
  }

  /// Command-Q in a focused terminal quits the app.
  @MainActor
  func testCommandQQuitsFromATerminal() throws {
    let live = MacLiveUITestSupport(self)
    let app = try openShell(live)
    defer { app.terminate() }

    live.quit(app)
  }

  /// A shell that exits leaves a card saying so, with Reattach, instead of a blank surface.
  @MainActor
  func testExitedShellShowsTheDeadTerminalCard() throws {
    let live = MacLiveUITestSupport(self)
    let app = try openShell(live)
    defer { app.terminate() }

    app.typeText("exit\r")
    XCTAssertTrue(
      live.element("terminal-status-card", in: app).waitForExistence(timeout: 30),
      "no card once the shell ended")
    XCTAssertTrue(live.text(containing: "Terminal ended", in: app).exists, "the card says nothing")
    XCTAssertTrue(live.element("terminal-reattach", in: app).exists, "no way to reattach")
  }

  /// Closing a shell tab asks first: Cancel keeps it and Close Shell closes it.
  @MainActor
  func testClosingAShellTabAsksFirst() throws {
    let live = MacLiveUITestSupport(self)
    let app = try openShell(live)
    defer { app.terminate() }
    let tab = live.tabs("terminal", in: app).firstMatch

    app.typeKey("w", modifierFlags: .command)
    live.clickDialogButton("Cancel", in: app)
    XCTAssertTrue(tab.exists, "Cancel closed the shell")

    app.typeKey("w", modifierFlags: .command)
    live.clickDialogButton("Close Shell", in: app)
    XCTAssertTrue(tab.waitForNonExistence(timeout: 15), "Close Shell left the tab")
  }

  /// Launches on the fixture session with a new shell started and focused.
  @MainActor
  private func openShell(_ live: MacLiveUITestSupport) throws -> XCUIApplication {
    let session = try live.fixtureSession()
    let app = live.launch()
    live.open(session, in: app)
    app.typeKey("t", modifierFlags: [.command, .option])
    XCTAssertTrue(
      live.tabs("terminal", in: app).firstMatch.waitForExistence(timeout: 30), "no terminal tab")
    live.click(live.element("terminal-tab", in: app), "the terminal", timeout: 30)
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { !live.element("terminal-starting", in: app).exists },
      "the terminal never started")
    return app
  }
}
