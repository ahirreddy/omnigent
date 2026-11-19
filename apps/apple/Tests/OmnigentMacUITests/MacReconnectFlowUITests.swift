import XCTest

/// The server going away under an open session and coming back: a warning shows while it is
/// gone, every warning clears once it is back, and "Reconnected" shows for a moment. The app runs
/// on a relay in front of the local server, so the server and its hosts keep running throughout.
final class MacReconnectFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Every line that says the connection had a problem.
  private static let warnings = [
    "connection.reconnecting", "connection.unreachable", "connection.issue",
    "composer-connection", "session-list-error", "sidebar-offline",
  ]

  @MainActor
  func testWarningsClearAndReconnectedShowsWhenTheServerComesBack() throws {
    let local = MacLiveUITestSupport(self)
    let session = try local.fixtureSession()
    let proxy = try MacFlowProxy(to: local.server)
    try proxy.start()
    addTeardownBlock { proxy.stop() }
    let live = MacLiveUITestSupport(self, server: proxy.server)
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    let back = live.element("connection.reconnected", in: app)
    XCTAssertFalse(back.appears(within: 3), "the first connect said Reconnected")

    proxy.stop()
    XCTAssertTrue(
      live.element("connection.reconnecting", in: app).appears(within: 20),
      "no warning once the server went away\n\(app.debugDescription)")
    live.shot(app, "reconnect-disconnected")

    try proxy.start()
    XCTAssertTrue(back.appears(within: 20), "no Reconnected once the server came back")
    live.shot(app, "reconnect-reconnected")
    XCTAssertTrue(back.disappears(within: 10), "Reconnected stayed")
    for warning in Self.warnings {
      XCTAssertTrue(
        live.element(warning, in: app).disappears(within: 10), "\(warning) outlived the reconnect")
    }
    XCTAssertTrue(live.element("transcript-\(session)", in: app).exists, "the session closed")
  }
}
