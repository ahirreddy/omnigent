import AppKit
import XCTest

/// The steps the Mac user-journey flows share: menus, dialogs, starting a demo session.
///
/// In the demo, demo-notes is read-only, and demo-design and demo-question wait on a request, so
/// they take no message: a flow that sends starts its own session with ``startDemoSession``.
extension MacLiveUITestSupport {
  /// The session's row in the sidebar.
  func row(_ sessionID: String, in app: XCUIApplication) -> XCUIElement {
    element("session-row-\(sessionID)", in: app)
  }

  /// The composer's text view.
  func composer(in app: XCUIApplication) -> XCUIElement {
    element("composer-input", in: app)
  }

  /// Clicks the composer once it takes input. While its session loads it is locked, and a
  /// click and the keys typed after it would go nowhere.
  func focusComposer(in app: XCUIApplication) {
    let composer = composer(in: app)
    _ = waitUntil(timeout: 5) { composer.exists && composer.isEnabled }
    click(composer, "the composer")
  }

  /// The composer's current text.
  func composerText(in app: XCUIApplication) -> String {
    composer(in: app).value as? String ?? ""
  }

  /// The shown session's transcript, whichever session that is.
  func anyTranscript(in app: XCUIApplication) -> XCUIElement {
    elements(prefix: "transcript-", in: app).firstMatch
  }

  /// The hittable element of `query`, once there is one. Closed menus and covered views stay in
  /// the accessibility tree, so existing is not enough; the last one is the frontmost.
  func hittable(_ query: XCUIElementQuery, timeout: TimeInterval = 5) -> XCUIElement? {
    var found: XCUIElement?
    _ = waitUntil(timeout: timeout) {
      found = query.allElementsBoundByIndex.last { $0.isHittable }
      return found != nil
    }
    return found
  }

  /// Clicks the open menu's item whose title starts with `title`.
  func clickMenuItem(
    _ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let items = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", title))
    guard let item = hittable(items) else {
      XCTFail("no menu item \(title)\n\(app.debugDescription)", file: file, line: line)
      return
    }
    item.click()
  }

  /// Right-clicks `target` and chooses `title` from its context menu.
  func contextMenu(
    _ target: XCUIElement, choose title: String, in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      target.appears(within: 30), "\(target) is missing", file: file, line: line)
    target.rightClick()
    clickMenuItem(title, in: app, file: file, line: line)
  }

  /// Clicks the button titled `title` of the alert or confirmation in front.
  func clickDialogButton(
    _ title: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) {
    let buttons = app.buttons.matching(
      NSPredicate(format: "title == %@ OR label == %@", title, title))
    guard let button = hittable(buttons, timeout: 10) else {
      XCTFail("no button \(title)\n\(app.debugDescription)", file: file, line: line)
      return
    }
    button.click()
  }

  /// Waits for the sample sessions to load, on the New Tab page's first launch.
  func waitForDemoSessions(in app: XCUIApplication) {
    XCTAssertTrue(
      row("demo-question", in: app).appears(within: 30), "the demo sessions did not load")
  }

  /// Opens the New Session page with Command-N.
  func openNewSession(in app: XCUIApplication) {
    waitForDemoSessions(in: app)
    let page = element("new-session-page", in: app)
    for _ in 0..<3 where !page.exists {
      app.typeKey("n", modifierFlags: .command)
      _ = page.appears(within: 10)
    }
    XCTAssertTrue(page.exists, "Command-N did not open the New Session page")
    XCTAssertTrue(composer(in: app).appears(within: 10), "the page has no composer")
  }

  /// Starts a demo session with `message`, from Command-N to its transcript. A message with "in
  /// detail" gets the long reply, slow enough to work with while it runs.
  func startDemoSession(_ message: String, in app: XCUIApplication) {
    openNewSession(in: app)
    send(message, in: app)
    XCTAssertTrue(
      anyTranscript(in: app).appears(within: 15), "the session did not start")
  }

  /// Starts a demo session and stops its reply, leaving it idle and ready for the next message.
  func startIdleDemoSession(in app: XCUIApplication) {
    startDemoSession("Start \(UUID().uuidString.prefix(6)) in detail", in: app)
    let stop = element("composer-stop", in: app)
    XCTAssertTrue(stop.appears(within: 15), "no reply started")
    click(stop, "Stop")
    XCTAssertTrue(stop.disappears(within: 15), "the reply did not stop")
  }

  /// Types `message` into the composer and sends it with Command-Return.
  func send(_ message: String, in app: XCUIApplication) {
    focusComposer(in: app)
    app.typeText(message)
    app.typeKey(.return, modifierFlags: .command)
  }

  /// Waits for `text` in the transcript, once the composer no longer holds it.
  func assertShows(
    _ text: String, in app: XCUIApplication, timeout: TimeInterval = 15,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(
      waitUntil(timeout: timeout) { !composerText(in: app).contains(text) },
      "the composer kept \(text)", file: file, line: line)
    XCTAssertTrue(
      self.text(containing: text, in: app).appears(within: timeout),
      "\(text) never showed", file: file, line: line)
  }

  /// Waits for the session row's accessibility label to include or leave `text`.
  func assertRow(
    _ sessionID: String, in app: XCUIApplication, contains text: String, _ expected: Bool = true,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let row = row(sessionID, in: app)
    XCTAssertTrue(
      waitUntil(timeout: 15) { row.exists && row.label.contains(text) == expected },
      "\(sessionID)'s row: expected \(expected ? "" : "no ")\(text) in \(row.label)",
      file: file, line: line)
  }

  /// Picks a scope (`All sessions`, `Archived sessions`, ...) from View > Session List. The
  /// sidebar's own display menu is in a section header, which is one accessibility element.
  func showDisplayScope(_ scope: String, in app: XCUIApplication) {
    click(app.menuBars.menuBarItems["View"], "the View menu")
    clickMenuItem("Session List", in: app)
    clickMenuItem("Display", in: app)
    clickMenuItem(scope, in: app)
  }

  /// Opens the shown session's menu from the toolbar. A narrow window folds the button into the
  /// toolbar's overflow menu, where the session's menu is a submenu.
  func openSessionMenu(in app: XCUIApplication) {
    let button = element("header-session-menu", in: app)
    if button.appears(within: 3), button.isHittable {
      button.click()
      return
    }
    click(app.toolbars.popUpButtons["more toolbar items"].firstMatch, "the toolbar's overflow")
    clickMenuItem("Session", in: app)
  }

  /// The right panel's section tabs, which show whenever the panel is open.
  func inspectorTabs(in app: XCUIApplication) -> XCUIElement {
    elements(prefix: "inspector-tab-", in: app).firstMatch
  }

  /// Opens the right panel if it is closed, with Option-Command-I: in a narrow window the
  /// toolbar's toggle is folded into the overflow menu.
  func showInspector(in app: XCUIApplication) {
    let tabs = inspectorTabs(in: app)
    if !tabs.exists { app.typeKey("i", modifierFlags: [.command, .option]) }
    XCTAssertTrue(tabs.appears(within: 10), "the right panel did not open")
  }

  /// Empties a search field, again if the keys were lost: a list that is still updating can
  /// take the keyboard between two key presses.
  func clear(_ search: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    let isEmpty = { (search.value as? String ?? "").isEmpty }
    for _ in 0..<3 where !isEmpty() {
      search.click()
      search.typeKey("a", modifierFlags: .command)
      search.typeKey(.delete, modifierFlags: [])
      _ = waitUntil(timeout: 3, isEmpty)
    }
    XCTAssertTrue(isEmpty(), "the search field kept \(search.value ?? "")", file: file, line: line)
  }

  /// Starts a shell in the shown session with Option-Command-T and waits until its tab has
  /// attached. Control-` is no way in: it shows the session's own terminal (the agent's, or the
  /// Omnigent REPL its runner hosts) when there is one, and a shell only when there is none.
  @discardableResult
  func openShellTab(
    in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line
  ) -> XCUIElement {
    // The command is off until the session's tabs are ready to take it; a key typed before
    // then is dropped.
    let command = app.menuBars.menuItems["New Shell"]
    _ = waitUntil(timeout: 5) { command.exists && command.isEnabled }
    app.typeKey("t", modifierFlags: [.command, .option])
    XCTAssertTrue(
      tabs("terminal", in: app).firstMatch.appears(within: 30), "no terminal tab",
      file: file, line: line)
    let surface = element("terminal-tab", in: app)
    waitForAttachedShell(surface, in: app, file: file, line: line)
    return surface
  }

  /// Waits for the shown shell tab to finish attaching: until then typing is dropped.
  func waitForAttachedShell(
    _ surface: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertTrue(
      surface.appears(within: 30), "no terminal is shown", file: file, line: line)
    XCTAssertTrue(
      waitUntil(timeout: 30) {
        !text(containing: "Attaching", in: app).exists
          && !text(containing: "Connecting", in: app).exists
      }, "the terminal never attached", file: file, line: line)
  }

  /// Quits with Command-Q, which saves windows and tabs, and waits for the app to exit.
  func quit(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(
      app.wait(for: .notRunning, timeout: 30), "Command-Q did not quit the app", file: file,
      line: line)
  }

  /// An HTML page with `title` in a scratch folder.
  func writePage(title: String) throws -> (url: URL, title: String) {
    let folder = Self.scratchDirectory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: "index.html")
    let html = "<!doctype html><title>\(title)</title><h1>\(title)</h1>"
    try html.write(to: url, atomically: true, encoding: .utf8)
    return (url, title)
  }

  /// Opens a browser tab in the shown session with Option-Command-B and loads `page` from its
  /// address field, waiting for the page's title.
  func openBrowserTab(
    loading page: (url: URL, title: String), in app: XCUIApplication,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(
      tabs("browser", in: app).firstMatch.appears(within: 20), "no browser tab", file: file,
      line: line)
    let omnibox = element("browser.omnibox", in: app)
    click(omnibox, "the address field", timeout: 20)
    let address = page.url.absoluteString
    // A new tab that is still loading its start page puts that address back: type again.
    for _ in 0..<3 {
      app.typeKey("a", modifierFlags: .command)
      app.typeText(address)
      if waitUntil(timeout: 2, { omnibox.value as? String == address }) { break }
    }
    app.typeText("\r")
    XCTAssertTrue(
      text(containing: page.title, in: app).appears(within: 30),
      "the page's title never showed\n\(app.debugDescription)", file: file, line: line)
  }

  /// A small text file in a scratch folder, for attaching.
  func writeTextFile(named name: String) throws -> URL {
    let folder = Self.scratchDirectory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appending(path: name)
    try "Attached by a Mac UI flow.\n".write(to: url, atomically: true, encoding: .utf8)
    return url
  }
}
