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

  /// View > Enter Full Screen grows the window to the whole screen, and Exit Full Screen
  /// restores it. By the menu: the key for it differs between macOS versions.
  @MainActor
  func testFullScreenFillsTheScreenAndLeaves() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let window = app.windows.firstMatch
    let before = window.frame

    app.menuBars.menuBarItems["View"].click()
    live.clickMenuItem("Enter Full Screen", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { window.frame.height > before.height }, "no full screen")
    live.assertRunning(app, "in full screen")
    // In full screen the menu bar hides until the pointer rests at the top of the screen.
    let viewMenu = app.menuBars.menuBarItems.matching(NSPredicate(format: "title == %@", "View"))
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).hover()
    guard let menu = live.hittable(viewMenu, timeout: 10) else {
      XCTFail("the menu bar did not show in full screen")
      return
    }
    menu.click()
    live.clickMenuItem("Exit Full Screen", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { window.frame == before },
      "the window did not return: \(window.frame) from \(before)")
  }

  /// Window > Zoom resizes the window. What a second Zoom returns to is the system's to choose:
  /// a window that opened as large as the screen has no smaller size to go back to.
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
    live.assertRunning(app, "after zooming twice")
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
      live.element("transcript-demo-question", in: app).appears(within: 30),
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
      live.tabs("newTab", in: app).firstMatch.appears(within: 10), "no new tab")
    live.quit(app)

    app = live.launchDemo(tabs: tabs)
    XCTAssertTrue(
      live.tabs("newTab", in: app).firstMatch.appears(within: 30),
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
    XCTAssertTrue(
      live.waitUntil(timeout: 20) { app.windows.count == windows + 1 },
      "no new window: \(app.windows.count) of \(windows) before")
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).appears(within: 20),
      "the window does not show the session")
  }

  /// A tab's Open in Split View shows it beside the session's chat. Split view holds two tabs
  /// of one session, so it is offered on tabs, not on the sidebar's rows.
  @MainActor
  func testOpenInSplitViewShowsTwoPanes() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    app.typeKey("t", modifierFlags: .command)
    let tab = live.tabs("newTab", in: app).firstMatch
    XCTAssertTrue(tab.appears(within: 10), "Command-T opened no tab")

    live.contextMenu(tab, choose: "Open in Split View", in: app)
    XCTAssertTrue(
      live.element("tab-split-divider", in: app).appears(within: 15), "no split")
    XCTAssertTrue(
      live.element("newtab-page", in: app).appears(within: 15),
      "the new pane does not show the tab")
    XCTAssertTrue(
      live.element("transcript-demo-notes", in: app).appears(within: 15),
      "the first pane does not show the chat")
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
    XCTAssertTrue(palette.appears(within: 10), "no palette")
    app.typeText("Choose the first release")
    XCTAssertTrue(
      live.elements(prefix: "palette-result-", in: app).firstMatch.appears(within: 10),
      "no result")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(palette.disappears(within: 10), "the palette stayed")
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).appears(within: 15),
      "the palette did not open the session")
  }

  /// Control-Command-Down and Up move through the sidebar's sessions; Command-[ goes back to the
  /// session shown before and Command-] forward again, as the web's desktop app.
  @MainActor
  func testPreviousAndNextSessionKeys() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)
    let start = live.element("transcript-demo-question", in: app)

    app.typeKey(.downArrow, modifierFlags: [.command, .control])
    if !start.disappears(within: 5) {
      // The first session was last in the list, so go the other way.
      app.typeKey(.upArrow, modifierFlags: [.command, .control])
      XCTAssertTrue(start.disappears(within: 10), "the keys did not change session")
    }
    app.typeKey("[", modifierFlags: .command)
    XCTAssertTrue(start.appears(within: 10), "Back did not return to the session")
    app.typeKey("]", modifierFlags: .command)
    XCTAssertTrue(start.disappears(within: 10), "Forward did not leave it again")
  }

  /// A quick Control-Tab, Control released at once, opens the next recently active session.
  @MainActor
  func testControlTabSwitchesToARecentSession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)
    let start = live.element("transcript-demo-question", in: app)
    XCTAssertTrue(start.appears(within: 10), "the session did not open")
    app.typeKey(.tab, modifierFlags: .control)
    XCTAssertTrue(start.disappears(within: 10), "Control-Tab did not switch session")
    XCTAssertFalse(
      live.element("recent-sessions-switcher", in: app).exists, "the switcher stayed open")
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
    XCTAssertTrue(approve.disappears(within: 15), "the request stayed")
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
    XCTAssertTrue(option.disappears(within: 15), "the question stayed")
    live.assertRow("demo-question", in: app, contains: "Needs you", false)
  }
}
