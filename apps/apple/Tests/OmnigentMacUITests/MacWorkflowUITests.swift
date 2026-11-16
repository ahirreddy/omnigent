import AppKit
import XCTest

/// The Mac app's everyday workflows on a live local server, end to end through real input: a
/// browser tab loading a page, a terminal running a command, jumping to a long transcript's
/// first message, sessions keeping their own tabs, and resizing the window over each tab
/// kind. Each step also checks that the app is still running, so a crash fails at the step that
/// caused it. See ``MacLiveUITestSupport`` for the seeded sessions each test needs.
final class MacWorkflowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  #if OMNIGENT_CHROMIUM
    /// Option-Command-B opens a Chromium tab in the session, and it loads a page typed into its
    /// address field.
    @MainActor
    func testBrowserTabLoadsAPage() throws {
      let live = MacLiveUITestSupport(self)
      let session = try live.fixtureSession()
      let page = try live.writePage(title: "Omnigent UI check \(UUID().uuidString.prefix(8))")
      let app = live.launch()
      defer { app.terminate() }
      live.open(session, in: app)

      live.openBrowserTab(loading: page, in: app)
      live.assertRunning(app, "after loading the page")
      live.shot(app, "browser-page")
    }
  #endif

  /// Option-Command-T starts a shell in a tab; typed input reaches it, and its command runs on
  /// the session's machine (it writes a file the test reads back). Control-` then goes to the
  /// chat, from the chat to the session's terminal, and back.
  @MainActor
  func testTerminalTabRunsACommand() throws {
    let live = MacLiveUITestSupport(self)
    try live.requireTerminals()
    let session = try live.fixtureSession()
    let marker = try live.fixtureWorkspace().appending(
      path: "terminal-check-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: marker) }
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    let surface = live.openShellTab(in: app)
    surface.click()
    app.typeText("echo terminal-ok > '\(marker.path)'\r")
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: marker.path) },
      "the command did not run (no \(marker.lastPathComponent))")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "terminal-ok\n")
    live.assertRunning(app, "after the command")
    live.shot(app, "terminal")

    // From the shell to the chat, and on to the session's terminal: its own in the chat's
    // Terminal view (the Omnigent REPL, once its runner hosts one), else its newest live shell,
    // the one opened here, not one an earlier flow left running.
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(live.element("transcript-\(session)", in: app).appears(within: 10))
    app.typeKey("`", modifierFlags: .control)
    let ownTerminal = live.element("session-terminal", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { ownTerminal.exists || (surface.exists && surface.isHittable) },
      "Control-` showed no terminal\n\(app.debugDescription)")
    if ownTerminal.exists {
      XCTAssertEqual(live.tabs("terminal", in: app).count, 1, "its own terminal opened a shell")
    }
    live.shot(app, "terminal-from-chat")
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(
      live.waitUntil(timeout: 10) {
        !ownTerminal.exists && !(surface.exists && surface.isHittable)
          && live.element("transcript-\(session)", in: app).exists
      }, "Control-` did not come back to the chat")
    live.assertRunning(app, "after toggling the terminal")
  }

  /// In a transcript of several pages, Jump to the first message pages in the older history
  /// and lands on the first message in one step. The session has a few pages, not hundreds of
  /// turns: UI automation reads every row of a transcript, and times out on thousands.
  @MainActor
  func testJumpReachesTheFirstMessageOfALongTranscript() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.pagedSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    // The scroll view itself, the widest one: the transcript's identifier is also on the buttons
    // over it and on the turn rail, a narrow scroll view at its leading edge.
    let scrollViews = app.scrollViews.matching(identifier: "transcript-\(session)")
    XCTAssertTrue(scrollViews.firstMatch.appears(within: 10), "no transcript to scroll")
    let transcript = try XCTUnwrap(
      scrollViews.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width })
    // The seed's first user message: its turns count from 1.
    let first = live.text(containing: "(step 1).", in: app)
    XCTAssertFalse(first.exists, "the transcript opened at its first message")

    // The button shows once the transcript has left its end.
    transcript.scroll(byDeltaX: 0, deltaY: 500)
    live.click(app.buttons["Jump to the first message"].firstMatch, "Jump to the first message")
    XCTAssertTrue(first.appears(within: 60), "the jump did not reach the first message")
    live.assertRunning(app, "after the jump")
    live.shot(app, "transcript-top")
  }

  /// A session's browser and terminal tabs stay with it: another session shows only its own
  /// tabs, and coming back restores them.
  @MainActor
  func testSessionsKeepTheirOwnTabs() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let other = try live.longSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    if MacLiveUITestSupport.hostHasTmux { live.openShellTab(in: app) }
    #if OMNIGENT_CHROMIUM
      app.typeKey("b", modifierFlags: [.command, .option])
      XCTAssertTrue(
        live.tabs("browser", in: app).firstMatch.appears(within: 20), "no browser tab")
    #endif
    let ownTabs = otherTabCount(live, app)
    try XCTSkipIf(ownTabs == 0, "This edition and host can open neither a browser nor a terminal.")

    live.open(other, in: app)
    XCTAssertTrue(
      live.waitUntil { otherTabCount(live, app) == 0 },
      "the other session shows the first one's tabs")
    live.assertRunning(app, "in the other session")

    live.open(session, in: app)
    XCTAssertTrue(
      live.waitUntil { otherTabCount(live, app) == ownTabs }, "coming back lost the session's tabs")
    live.assertRunning(app, "back in the first session")
  }

  /// Resizing the window, narrow to wide, over a chat, a terminal and a browser tab: each width
  /// lays the tab out again without a layout exception.
  @MainActor
  func testResizingTheWindowOverEachTabKind() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    let window = app.windows.firstMatch
    resizeThroughWidths(window, live, app, "chat")

    if MacLiveUITestSupport.hostHasTmux {
      live.openShellTab(in: app)
      resizeThroughWidths(window, live, app, "terminal")
    }

    #if OMNIGENT_CHROMIUM
      app.typeKey("b", modifierFlags: [.command, .option])
      XCTAssertTrue(
        live.tabs("browser", in: app).firstMatch.appears(within: 20), "no browser tab")
      resizeThroughWidths(window, live, app, "browser")
    #endif
  }

  // MARK: Helpers

  /// How many tabs besides chats the shown session's strip has.
  @MainActor
  private func otherTabCount(_ live: MacLiveUITestSupport, _ app: XCUIApplication) -> Int {
    live.tabs("terminal", in: app).count + live.tabs("browser", in: app).count
  }

  /// Drags the window's bottom-right corner narrow, wide, narrow and as wide as the screen,
  /// checking the app after each.
  @MainActor
  private func resizeThroughWidths(
    _ window: XCUIElement, _ live: MacLiveUITestSupport, _ app: XCUIApplication, _ kind: String
  ) {
    for widthChange in [-500.0, 700, -350, 1200] {
      let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        .withOffset(CGVector(dx: -2, dy: -2))
      corner.press(
        forDuration: 0.2,
        thenDragTo: corner.withOffset(CGVector(dx: widthChange, dy: widthChange / 4)))
      live.assertRunning(app, "after resizing the \(kind) tab by \(widthChange)")
    }
    live.shot(app, "resized-\(kind)")
  }
}
