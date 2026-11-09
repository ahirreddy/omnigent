import XCTest

/// A session's tab strip on the offline demo server: the New Tab page, closing and reopening, and
/// each session keeping its own tabs.
final class MacTabFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Command-T shows the New Tab page with the session's launchers.
  @MainActor
  func testNewTabPageOffersItsLaunchers() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(
      live.element("newtab-page", in: app).waitForExistence(timeout: 10), "no New Tab page")
    XCTAssertTrue(live.element("newtab-terminal", in: app).exists, "no Terminal launcher")
  }

  /// Shift-Command-[ and Shift-Command-] move between the session's tabs.
  @MainActor
  func testShiftCommandBracketsMoveBetweenTabs() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    app.typeKey("t", modifierFlags: .command)
    let page = live.element("newtab-page", in: app)
    XCTAssertTrue(page.waitForExistence(timeout: 10), "no New Tab page")

    app.typeKey("[", modifierFlags: [.command, .shift])
    XCTAssertTrue(
      live.element("transcript-demo-notes", in: app).waitForExistence(timeout: 10),
      "Shift-Command-[ did not show the chat")
    app.typeKey("]", modifierFlags: [.command, .shift])
    XCTAssertTrue(page.waitForExistence(timeout: 10), "Shift-Command-] did not show the page")
  }

  /// A tab's close button removes that tab and leaves the chat.
  @MainActor
  func testCloseButtonClosesATab() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    app.typeKey("t", modifierFlags: .command)
    let tab = live.tabs("newTab", in: app).firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 10), "Command-T opened no tab")

    tab.hover()
    live.click(live.elements(prefix: "tab-close-", in: app).firstMatch, "the close button")
    XCTAssertTrue(tab.waitForNonExistence(timeout: 10), "the tab stayed")
    XCTAssertTrue(
      live.element("transcript-demo-notes", in: app).waitForExistence(timeout: 10),
      "closing the tab did not return to the chat")
  }

  /// A session's tabs stay with it: another session has none of them, and they come back with it.
  @MainActor
  func testEachSessionKeepsItsOwnTabs() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let tabs = live.tabs("newTab", in: app)
    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { tabs.count == 1 }, "Command-T opened no tab")

    live.openDemo("demo-question", in: app)
    XCTAssertTrue(
      live.waitUntil { !tabs.firstMatch.exists }, "the other session shows the first's tab")

    live.click(live.row("demo-notes", in: app), "the first session")
    XCTAssertTrue(live.waitUntil { tabs.count == 1 }, "coming back lost the tab")
  }

  #if OMNIGENT_CHROMIUM
    /// Closing a browser tab with its button, then Shift-Command-T brings it back.
    @MainActor
    func testClosedBrowserTabReopens() {
      let live = MacLiveUITestSupport(self)
      let app = live.launchDemo()
      defer { app.terminate() }
      live.openDemo("demo-question", in: app)
      app.typeKey("b", modifierFlags: [.command, .option])
      let tab = live.tabs("browser", in: app).firstMatch
      XCTAssertTrue(tab.waitForExistence(timeout: 20), "Option-Command-B opened no browser tab")

      tab.hover()
      live.click(live.elements(prefix: "tab-close-", in: app).firstMatch, "the close button")
      XCTAssertTrue(tab.waitForNonExistence(timeout: 10), "the tab stayed")
      app.typeKey("t", modifierFlags: [.command, .shift])
      XCTAssertTrue(
        live.tabs("browser", in: app).firstMatch.waitForExistence(timeout: 20),
        "Shift-Command-T did not reopen the browser tab")
    }
  #endif
}
