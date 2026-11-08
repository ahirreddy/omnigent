import AppKit
import XCTest

/// The Mac app's everyday workflows on a live local server, end to end through real input: a
/// browser tab loading a page, a terminal running a command, scrolling a long transcript back to
/// its first message, sessions keeping their own tabs, and resizing the window over each tab
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
      let page = try writePage(title: "Omnigent UI check \(UUID().uuidString.prefix(8))")
      let app = live.launch()
      defer { app.terminate() }
      live.open(session, in: app)

      app.typeKey("b", modifierFlags: [.command, .option])
      XCTAssertTrue(
        live.tabs("browser", in: app).firstMatch.waitForExistence(timeout: 20), "no browser tab")
      let omnibox = live.element("browser.omnibox", in: app)
      live.click(omnibox, "the address field", timeout: 20)
      app.typeKey("a", modifierFlags: .command)
      app.typeText(page.url.absoluteString + "\r")
      XCTAssertTrue(
        live.text(containing: page.title, in: app).waitForExistence(timeout: 30),
        "the page's title never showed\n\(app.debugDescription)")
      live.assertRunning(app, "after loading the page")
      live.shot(app, "browser-page")
    }

    /// An HTML page with `title` in a scratch folder.
    private func writePage(title: String) throws -> (url: URL, title: String) {
      let folder = FileManager.default.temporaryDirectory.appending(
        path: "omnigent-page-\(UUID().uuidString)", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let url = folder.appending(path: "index.html")
      let html = "<!doctype html><title>\(title)</title><h1>\(title)</h1>"
      try html.write(to: url, atomically: true, encoding: .utf8)
      return (url, title)
    }
  #endif

  /// Control-` starts the session's shell in a tab; typed input reaches it, and its command runs
  /// on the session's machine (it writes a file the test reads back).
  @MainActor
  func testTerminalTabRunsACommand() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let marker = try live.fixtureWorkspace().appending(
      path: "terminal-check-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: marker) }
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(
      live.tabs("terminal", in: app).firstMatch.waitForExistence(timeout: 30), "no terminal tab")
    let surface = live.element("terminal-tab", in: app)
    live.click(surface, "the terminal", timeout: 30)
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { !live.element("terminal-starting", in: app).exists },
      "the terminal never started")
    app.typeText("echo terminal-ok > '\(marker.path)'\r")
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { FileManager.default.fileExists(atPath: marker.path) },
      "the command did not run (no \(marker.lastPathComponent))")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "terminal-ok\n")
    live.assertRunning(app, "after the command")

    // Back to the chat and to the terminal again: the same shell, not a new one.
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(live.element("transcript-\(session)", in: app).waitForExistence(timeout: 10))
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(surface.waitForExistence(timeout: 10), "the terminal did not come back")
    XCTAssertEqual(live.tabs("terminal", in: app).count, 1, "toggling opened a second terminal")
    live.assertRunning(app, "after toggling the terminal")
    live.shot(app, "terminal")
  }

  /// Scrolling up a transcript of hundreds of turns pages in older history until its first
  /// message, and Jump to the first message gets there in one step.
  @MainActor
  func testScrollingBackReachesTheFirstMessage() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.longSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    let transcript = live.element("transcript-\(session)", in: app)
    // The long seed's first user message.
    let first = live.text(containing: "(step 0).", in: app)

    var scrolls = 0
    while !first.exists, scrolls < 150 {
      transcript.scroll(byDeltaX: 0, deltaY: 3000)
      scrolls += 1
      if scrolls.isMultiple(of: 10) { live.assertRunning(app, "after \(scrolls) scrolls") }
    }
    XCTAssertTrue(first.exists, "scrolling up \(scrolls) times did not reach the first message")
    live.assertRunning(app, "at the first message")
    live.shot(app, "transcript-top-by-scrolling")

    // From the end again, the jump button goes straight to the top.
    app.typeKey(.downArrow, modifierFlags: .command)
    transcript.scroll(byDeltaX: 0, deltaY: 500)
    let jump = live.element("transcript-jump-top", in: app)
    live.click(jump, "Jump to the first message")
    XCTAssertTrue(first.waitForExistence(timeout: 30), "the jump did not reach the first message")
    live.assertRunning(app, "after the jump")
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
    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(
      live.tabs("terminal", in: app).firstMatch.waitForExistence(timeout: 30), "no terminal tab")
    #if OMNIGENT_CHROMIUM
      app.typeKey("b", modifierFlags: [.command, .option])
      XCTAssertTrue(
        live.tabs("browser", in: app).firstMatch.waitForExistence(timeout: 20), "no browser tab")
    #endif
    let ownTabs = otherTabCount(live, app)

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

    app.typeKey("`", modifierFlags: .control)
    XCTAssertTrue(
      live.element("terminal-tab", in: app).waitForExistence(timeout: 30), "no terminal")
    resizeThroughWidths(window, live, app, "terminal")

    #if OMNIGENT_CHROMIUM
      app.typeKey("b", modifierFlags: [.command, .option])
      XCTAssertTrue(
        live.tabs("browser", in: app).firstMatch.waitForExistence(timeout: 20), "no browser tab")
      resizeThroughWidths(window, live, app, "browser")
    #endif
  }

  // MARK: Helpers

  /// How many tabs besides chats the shown session's strip has.
  @MainActor
  private func otherTabCount(_ live: MacLiveUITestSupport, _ app: XCUIApplication) -> Int {
    live.tabs("terminal", in: app).count + live.tabs("browser", in: app).count
  }

  /// Drags the window's bottom-right corner narrow, wide and back, checking the app after each.
  @MainActor
  private func resizeThroughWidths(
    _ window: XCUIElement, _ live: MacLiveUITestSupport, _ app: XCUIApplication, _ kind: String
  ) {
    for widthChange in [-500.0, 700, -350, 150] {
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
