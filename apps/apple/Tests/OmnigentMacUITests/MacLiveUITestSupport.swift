import AppKit
import XCTest

/// Shared steps of the Mac UI tests that drive the app on a live local server
/// (`TEST_RUNNER_OMNIGENT_E2E_SERVER_URL`, default http://127.0.0.1:6767) and its seeded
/// sessions: the fixture session (`TEST_RUNNER_OMNIGENT_UITEST_SESSION`, from
/// `Tools/seed-ui-test-fixtures.py`) and a long transcript (`TEST_RUNNER_OMNIGENT_LONG_SESSION`,
/// from `Tools/seed-large-fixtures.py`). Tests skip when their session is not seeded.
///
/// They take the real mouse and keyboard, so run them in a VM (`vm-test.sh`), not on a Mac in use.
@MainActor
struct MacLiveUITestSupport {
  let test: XCTestCase
  let server: String

  init(_ test: XCTestCase) {
    self.test = test
    server = Self.environment["OMNIGENT_E2E_SERVER_URL"] ?? "http://127.0.0.1:6767"
  }

  nonisolated static var environment: [String: String] { ProcessInfo.processInfo.environment }

  /// The seeded fixture session, or a skip when the run has none.
  func fixtureSession() throws -> String {
    try seeded("OMNIGENT_UITEST_SESSION", "Seed with Tools/seed-ui-test-fixtures.py")
  }

  /// The fixture session's workspace folder on this Mac.
  func fixtureWorkspace() throws -> URL {
    URL(
      filePath: try seeded("OMNIGENT_UITEST_WORKSPACE", "Seed with Tools/seed-ui-test-fixtures.py"),
      directoryHint: .isDirectory)
  }

  /// A seeded session with hundreds of turns, or a skip when the run has none.
  func longSession() throws -> String {
    try seeded("OMNIGENT_LONG_SESSION", "Seed with Tools/seed-large-fixtures.py")
  }

  /// The seeded session with a few pages of short history: enough to page, and small enough
  /// for UI automation to read whole. `Tools/seed-ui-test-fixtures.py` gives it this id.
  func pagedSession() throws -> String {
    _ = try fixtureSession()
    return "ceae1edc3ad8513a5bf6d0bedcbd9f1d"
  }

  /// A saved frame for the main window, as large as the screen allows, so a flow that resizes
  /// the window does not shape the next flow's. SwiftUI saves it under the scene's type name.
  nonisolated static let windowFrameArguments = ["OmnigentMac", "OmnigentMacAppStore"].flatMap {
    [
      "-NSWindow Frame SwiftUI.PresentedWindowContent<OmnigentDesktop.ServerWindowID, "
        + "OmnigentDesktop.WindowMinimumSize<\($0).ServerWindowRoot>>-1-AppWindow-1",
      "0 0 1440 900 0 0 1440 900 ",
    ]
  }

  /// Whether this Mac, which hosts the seeded sessions, has the tmux their terminals run in.
  nonisolated static var hostHasTmux: Bool {
    ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"].contains {
      FileManager.default.isExecutableFile(atPath: $0)
    }
  }

  /// Skips a flow that opens a terminal when the session's host cannot start one.
  func requireTerminals() throws {
    try XCTSkipUnless(
      Self.hostHasTmux,
      "Terminals need tmux 3.3 or newer on the session's host; install it (brew install tmux).")
  }

  private func seeded(_ key: String, _ how: String) throws -> String {
    guard let value = Self.environment[key], !value.isEmpty else {
      throw XCTSkip("\(how); pass TEST_RUNNER_\(key).")
    }
    return value
  }

  /// Launches the app on the server with no restored windows and tabs saved apart.
  func launch() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments =
      ["-desktop.defaultServerURL", server, "-OmnigentTabsDirectory", Self.scratchDirectory().path]
      + Self.freshStateArguments
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.appears(within: 30), "no window")
    MacNotificationPrompts.decline(waiting: 3)
    parkPointer(in: app)
    return app
  }

  /// Launches the app on the core's offline demo server (`-OmnigentDemo`).
  /// - Parameters:
  ///   - tabs: Where tabs are saved; pass the same folder to a relaunch to restore them.
  ///   - arguments: More launch arguments: preferences that hold for this launch only.
  /// - Returns: The app.
  func launchDemo(tabs: URL = Self.scratchDirectory(), arguments: [String] = [])
    -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments =
      [
        "-OmnigentDemo", "YES", "-desktop.defaultServerURL", "http://127.0.0.1:6767",
        "-OmnigentTabsDirectory", tabs.path,
      ] + Self.freshStateArguments + arguments
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.appears(within: 30), "no window")
    MacNotificationPrompts.decline(waiting: 3)
    parkPointer(in: app)
    return app
  }

  /// Moves the pointer off the sidebar, where the last flow may have left it: a row under the
  /// pointer shows its hover buttons instead of its status.
  private func parkPointer(in app: XCUIApplication) {
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).hover()
  }

  /// A folder of this run's own for saved tabs, never the user's.
  nonisolated static func scratchDirectory() -> URL {
    FileManager.default.temporaryDirectory.appending(
      path: "omnigent-mac-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
  }

  /// No restored windows or notification prompt, the right panel closed, and the sidebar's saved
  /// options discarded (undecodable ones fall back to the defaults), so no test inherits a scope.
  nonisolated static let freshStateArguments =
    [
      "-ApplePersistenceIgnoreState", "YES", "-OmnigentNoNotificationPrompt", "YES",
      "-omnigent:default-workspace-panel", "collapsed", "-omnigent:sidebar-view", "<7b7d>",
    ] + noLocalServerArguments + windowFrameArguments

  /// A CLI and a data folder that are not there, so the app neither starts This Mac's server nor
  /// finds one already running. With either, it moves a window on a loopback server to it.
  nonisolated static let noLocalServerArguments = [
    "-desktop.localServer.cliPath", "/var/empty/no-omnigent-cli-in-ui-tests",
    "-desktop.localServer.dataDirectory", "/var/empty/no-omnigent-data-in-ui-tests",
  ]

  /// Opens a demo session (demo-notes, demo-design, demo-question) from the sidebar and waits for
  /// its composer.
  func openDemo(_ sessionID: String, in app: XCUIApplication) {
    let row = element("session-row-\(sessionID)", in: app)
    let transcript = element("transcript-\(sessionID)", in: app)
    // Right after launch the window can still be settling on its server; a click can be lost.
    for _ in 0..<3 where !transcript.exists {
      clickTitle(of: row, "the \(sessionID) row", timeout: 30)
      _ = transcript.appears(within: 10)
    }
    XCTAssertTrue(transcript.exists, "\(sessionID) did not open\n\(app.debugDescription)")
    assertRunning(app, "after opening \(sessionID)")
  }

  /// Opens a session by its link, as the system would, and waits for its transcript.
  func open(_ sessionID: String, in app: XCUIApplication) {
    let transcript = element("transcript-\(sessionID)", in: app)
    let link = Self.sessionLink(server: server, sessionID: sessionID)
    for _ in 0..<3 where !transcript.exists {
      // Right after launch the window can still be connecting; a link then may be dropped.
      if let link { deliver(link) }
      _ = transcript.appears(within: 20)
    }
    XCTAssertTrue(transcript.exists, "session \(sessionID) did not open\n\(app.debugDescription)")
    // The app asks to send notifications once it has connected to a server.
    MacNotificationPrompts.decline(waiting: 0)
    assertRunning(app, "after opening \(sessionID)")
  }

  /// Hands `link` to the running app, as the system does for a clicked link.
  /// `XCUIApplication.open` would start a second copy of the app beside the one under test.
  private func deliver(_ link: URL) {
    guard let bundle = Self.runningAppUnderTest()?.bundleURL else {
      XCTFail("the app under test is not running, so nothing can take \(link)")
      return
    }
    let delivered = test.expectation(description: "the link reached the app")
    NSWorkspace.shared.open(
      [link], withApplicationAt: bundle, configuration: NSWorkspace.OpenConfiguration()
    ) { _, error in
      if let error { XCTFail("the system could not open \(link): \(error)") }
      delivered.fulfill()
    }
    test.wait(for: [delivered], timeout: 30)
  }

  /// The launched app: the one built beside this test runner, whichever edition that is.
  private static func runningAppUnderTest() -> NSRunningApplication? {
    let products = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
    return NSWorkspace.shared.runningApplications.first { candidate in
      candidate != .current
        && candidate.bundleURL?.deletingLastPathComponent().resolvingSymlinksInPath() == products
    }
  }

  /// The session's deep link on the server.
  nonisolated static func sessionLink(server: String, sessionID: String) -> URL? {
    guard let url = URL(string: server), let host = url.host() else { return nil }
    return URL(string: "omnigent://\(host)\(url.port.map { ":\($0)" } ?? "")/c/\(sessionID)")
  }

  /// The element with `identifier`, of any type.
  func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
    app.descendants(matching: .any)[identifier].firstMatch
  }

  /// The elements whose identifier starts with `prefix`.
  func elements(prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", prefix))
  }

  /// The strip's tabs of one kind (chat, terminal, browser, newTab, ...).
  func tabs(_ kind: String, in app: XCUIApplication) -> XCUIElementQuery {
    elements(prefix: "tab-\(kind)-", in: app)
  }

  /// Any element whose label contains `text`, or text element whose value does. Values are read
  /// only from text elements: `value CONTAINS` on a number (a scroll bar's, a splitter's) never
  /// returns, and the query times out.
  func text(containing text: String, in app: XCUIApplication) -> XCUIElement {
    let textTypes: [XCUIElement.ElementType] = [.staticText, .textView, .textField, .searchField]
    return app.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS %@ OR (elementType IN %@ AND value CONTAINS %@)",
        argumentArray: [text, textTypes.map(\.rawValue), text])
    ).firstMatch
  }

  /// Waits for `element` and clicks it, failing with `name` when it never shows.
  func click(_ element: XCUIElement, _ name: String, timeout: TimeInterval = 10) {
    XCTAssertTrue(element.appears(within: timeout), "\(name) is missing")
    element.click()
  }

  /// Clicks a sidebar row on its title. Under the pointer a row shows Pin and More at its
  /// trailing edge, and the row's own click point then lands on More, which opens a menu.
  func clickTitle(of row: XCUIElement, _ name: String, timeout: TimeInterval = 10) {
    XCTAssertTrue(row.appears(within: timeout), "\(name) is missing")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
  }

  /// Fails when the app is no longer running in front: a crash or a hang that killed it.
  func assertRunning(
    _ app: XCUIApplication, _ step: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertEqual(
      app.state, .runningForeground, "the app is not running \(step)", file: file, line: line)
  }

  /// Polls `condition` every 0.2 s until it holds or `timeout` passes.
  func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }
    return condition()
  }

  /// Attaches a screenshot of the app's window, kept with the result bundle.
  func shot(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    test.add(attachment)
  }
}

extension XCUIElement {
  /// How often ``appears(within:)`` and ``disappears(within:)`` look again.
  private static let pollInterval: TimeInterval = 0.1

  /// Whether the element exists within `timeout`: looked for at once, then every 0.1 s.
  /// `waitForExistence(timeout:)` first looks a second after it is called, so it costs a second
  /// even for an element that is already there.
  @MainActor
  func appears(within timeout: TimeInterval) -> Bool {
    poll(until: timeout) { exists }
  }

  /// Whether the element is gone within `timeout`: looked for at once, then every 0.1 s.
  @MainActor
  func disappears(within timeout: TimeInterval) -> Bool {
    poll(until: timeout) { !exists }
  }

  @MainActor
  private func poll(until timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if condition() { return true }
      guard Date() < deadline else { return false }
      RunLoop.current.run(until: Date().addingTimeInterval(Self.pollInterval))
    }
  }
}
