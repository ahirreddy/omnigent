import AppKit
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

  /// The New Tab page's Terminal launcher opens a shell in the page's session with one click,
  /// however many terminals the agent declares.
  @MainActor
  func testNewTabPageOpensATerminal() throws {
    let live = MacLiveUITestSupport(self)
    try live.requireTerminals()
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    app.typeKey("t", modifierFlags: .command)

    live.click(live.element("newtab-terminal", in: app), "the Terminal launcher")
    XCTAssertTrue(
      live.tabs("terminal", in: app).firstMatch.appears(within: 30), "no terminal tab")
    XCTAssertTrue(live.element("terminal-tab", in: app).appears(within: 30))
  }

  /// The + button's menu opens a shell in a new tab of the session, without the New Tab page.
  @MainActor
  func testPlusMenuOpensATerminal() throws {
    let live = MacLiveUITestSupport(self)
    try live.requireTerminals()
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    let plus = live.element("tab-new", in: app)
    waitUntilSettled(plus, live, app)
    live.click(plus, "the + button", timeout: 30)
    live.clickMenuItem("Terminal", in: app)
    XCTAssertTrue(
      live.tabs("terminal", in: app).firstMatch.appears(within: 30), "no terminal tab")
    XCTAssertFalse(live.tabs("newTab", in: app).firstMatch.exists, "+ opened the New Tab page")
  }

  /// A new shell takes the keyboard: typing reaches it without a click, and again after
  /// switching to the chat (Control-`) and back to the shell's tab (Command-2).
  @MainActor
  func testANewTerminalTakesTheKeyboard() throws {
    let live = MacLiveUITestSupport(self)
    try live.requireTerminals()
    let session = try live.fixtureSession()
    let workspace = try live.fixtureWorkspace()
    let opened = workspace.appending(path: "terminal-focus-\(UUID().uuidString).txt")
    let shownAgain = workspace.appending(path: "terminal-refocus-\(UUID().uuidString).txt")
    defer {
      for marker in [opened, shownAgain] { try? FileManager.default.removeItem(at: marker) }
    }
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    let surface = live.openShellTab(in: app)
    typesWithoutAClick(into: opened, live: live, app: app)
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(live.element("transcript-\(session)", in: app).appears(within: 10))
    // Not Control-` again: from the chat it shows the session's own terminal, not this shell.
    app.typeKey("2", modifierFlags: .command)
    live.waitForAttachedShell(surface, in: app)
    typesWithoutAClick(into: shownAgain, live: live, app: app)
  }

  /// Waits for the session's Chat and Terminal switch, which arrives with its toolbar once it
  /// loads and pushes the tab strip's buttons aside, then for `element` to stay put for a second.
  @MainActor
  private func waitUntilSettled(
    _ element: XCUIElement, _ live: MacLiveUITestSupport, _ app: XCUIApplication
  ) {
    XCTAssertTrue(
      live.element("session-view-mode", in: app).appears(within: 30),
      "the session's toolbar never showed its Chat and Terminal switch")
    var lastFrame = CGRect.null
    var stillSince = Date()
    let settled = live.waitUntil(timeout: 15) {
      let frame = element.exists ? element.frame : .null
      if frame != lastFrame {
        lastFrame = frame
        stillSince = Date()
      }
      return !frame.isNull && Date().timeIntervalSince(stillSince) >= 1
    }
    XCTAssertTrue(settled, "\(element) kept moving: \(lastFrame)")
  }

  /// Types a command that writes `marker` into the shown terminal, and waits for the file.
  @MainActor
  private func typesWithoutAClick(
    into marker: URL, live: MacLiveUITestSupport, app: XCUIApplication
  ) {
    app.typeText("echo focused > '\(marker.path)'\r")
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: marker.path) },
      "typing did not reach the terminal (no \(marker.lastPathComponent))")
  }

  /// Command-T in a focused terminal is the app's, not the shell's: a New Tab page opens.
  @MainActor
  func testCommandTOpensATabFromATerminal() throws {
    let live = MacLiveUITestSupport(self)
    let app = try openShell(live)
    defer { app.terminate() }

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      live.element("newtab-page", in: app).appears(within: 10),
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
      live.element("terminal-status-card", in: app).appears(within: 30),
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
    XCTAssertTrue(tab.disappears(within: 15), "Close Shell left the tab")
  }

  /// A right-click on the terminal shows its edit menu, and Paste there types the clipboard
  /// into the shell: the pasted command runs and writes a file.
  @MainActor
  func testContextMenuPastesIntoTheShell() throws {
    let live = MacLiveUITestSupport(self)
    let marker = try live.fixtureWorkspace().appending(
      path: "terminal-paste-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: marker) }
    let app = try openShell(live)
    defer { app.terminate() }

    NSPasteboard.general.clearContents()
    XCTAssertTrue(
      NSPasteboard.general.setString("echo pasted > '\(marker.path)'", forType: .string),
      "the pasteboard refused the command")
    live.contextMenu(live.element("terminal-tab", in: app), choose: "Paste", in: app)
    app.typeText("\r")
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: marker.path) },
      "Paste did not reach the shell (no \(marker.lastPathComponent))")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "pasted\n")
  }

  /// Launches on the fixture session with a new shell started and focused.
  @MainActor
  private func openShell(_ live: MacLiveUITestSupport) throws -> XCUIApplication {
    try live.requireTerminals()
    let session = try live.fixtureSession()
    let app = live.launch()
    live.open(session, in: app)
    live.openShellTab(in: app).click()
    return app
  }
}
