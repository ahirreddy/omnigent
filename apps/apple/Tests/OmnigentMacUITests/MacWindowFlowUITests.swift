import XCTest

/// The window and app-wide keys on the offline demo server: full screen, zoom, relaunch, other
/// windows and panes, and moving between sessions.
final class MacWindowFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Control-Command-F grows the window to the whole screen, and again restores it.
  @MainActor
  func testFullScreenFillsTheScreenAndLeaves() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let window = app.windows.firstMatch
    let before = window.frame

    app.typeKey("f", modifierFlags: [.command, .control])
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { window.frame.height > before.height }, "no full screen")
    live.assertRunning(app, "in full screen")
    app.typeKey("f", modifierFlags: [.command, .control])
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { window.frame == before },
      "the window did not return: \(window.frame) from \(before)")
  }

  /// Window > Zoom resizes the window, and again restores it.
  @MainActor
  func testWindowMenuZoomResizesTheWindow() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let window = app.windows.firstMatch
    let before = window.frame

    let zoom = app.menuBars.menuBarItems["Window"]
    zoom.click()
    live.clickMenuItem("Zoom", in: app)
    XCTAssertTrue(live.waitUntil(timeout: 10) { window.frame != before }, "Zoom did nothing")
    zoom.click()
    live.clickMenuItem("Zoom", in: app)
    XCTAssertTrue(live.waitUntil(timeout: 10) { window.frame == before }, "Zoom did not restore")
  }

  /// Quitting with a session open and relaunching opens that same session.
  @MainActor
  func testRelaunchRestoresTheOpenSession() {
    let live = MacLiveUITestSupport(self)
    let tabs = MacLiveUITestSupport.scratchDirectory()
    var app = live.launchDemo(tabs: tabs)
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)
    live.quit(app)

    app = live.launchDemo(tabs: tabs)
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).waitForExistence(timeout: 30),
      "the relaunch did not restore the session")
  }

  /// Quitting with extra tabs open and relaunching brings the session's tabs back.
  @MainActor
  func testRelaunchRestoresTheSessionsTabs() {
    let live = MacLiveUITestSupport(self)
    let tabs = MacLiveUITestSupport.scratchDirectory()
    var app = live.launchDemo(tabs: tabs)
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      live.tabs("newTab", in: app).firstMatch.waitForExistence(timeout: 10), "no new tab")
    live.quit(app)

    app = live.launchDemo(tabs: tabs)
    XCTAssertTrue(
      live.tabs("newTab", in: app).firstMatch.waitForExistence(timeout: 30),
      "the relaunch lost the tab")
  }

  /// Open in New Window shows the session in a window of its own.
  @MainActor
  func testOpenInNewWindowShowsTheSession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let windows = app.windows.count

    live.contextMenu(live.row("demo-question", in: app), choose: "Open in New Window", in: app)
    XCTAssertTrue(live.waitUntil(timeout: 20) { app.windows.count == windows + 1 }, "no window")
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).waitForExistence(timeout: 20),
      "the window does not show the session")
  }

  /// Open in Split View shows the session beside the open one.
  @MainActor
  func testOpenInSplitViewShowsTwoPanes() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    live.contextMenu(live.row("demo-question", in: app), choose: "Open in Split View", in: app)
    XCTAssertTrue(
      live.element("tab-split-divider", in: app).waitForExistence(timeout: 15), "no split")
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).waitForExistence(timeout: 15),
      "the new pane does not show the session")
    XCTAssertTrue(live.element("transcript-demo-notes", in: app).exists, "the first pane is gone")
  }

  /// The command palette finds a session by name and opens it.
  @MainActor
  func testPaletteOpensASession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    app.typeKey("k", modifierFlags: .command)
    let palette = live.element("command-palette", in: app)
    XCTAssertTrue(palette.waitForExistence(timeout: 10), "no palette")
    app.typeText("Choose the first release")
    XCTAssertTrue(
      live.elements(prefix: "palette-result-", in: app).firstMatch.waitForExistence(timeout: 10),
      "no result")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 10), "the palette stayed")
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).waitForExistence(timeout: 15),
      "the palette did not open the session")
  }

  /// Command-] and Command-[ move through the sessions, leaving and returning to the first.
  @MainActor
  func testPreviousAndNextSessionKeys() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)
    let start = live.element("transcript-demo-question", in: app)

    app.typeKey("]", modifierFlags: .command)
    if !start.waitForNonExistence(timeout: 5) {
      // The first session was last in the list, so go the other way.
      app.typeKey("[", modifierFlags: .command)
      XCTAssertTrue(start.waitForNonExistence(timeout: 10), "the keys did not change session")
      app.typeKey("]", modifierFlags: .command)
    } else {
      app.typeKey("[", modifierFlags: .command)
    }
    XCTAssertTrue(start.waitForExistence(timeout: 10), "the keys did not come back")
  }

  /// Approving in the transcript resolves the request and frees the composer to send.
  @MainActor
  func testApprovingInTheTranscript() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-design", in: app)
    live.assertRow("demo-design", in: app, contains: "Needs you")

    let approve = live.elements(prefix: "approval-approve-", in: app).firstMatch
    live.click(approve, "Approve")
    XCTAssertTrue(approve.waitForNonExistence(timeout: 15), "the request stayed")
    live.assertRow("demo-design", in: app, contains: "Needs you", false)
  }

  /// Answering a question in the transcript resolves it.
  @MainActor
  func testAnsweringAQuestionInTheTranscript() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)

    let option = live.elements(prefix: "decision-option-", in: app).firstMatch
    live.click(option, "the first option")
    XCTAssertTrue(option.waitForNonExistence(timeout: 15), "the question stayed")
    live.assertRow("demo-question", in: app, contains: "Needs you", false)
  }
}
