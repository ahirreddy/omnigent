import UIKit
import XCTest

/// iPad shell journeys against the local server (`TEST_RUNNER_OMNIGENT_SERVER`, default
/// http://127.0.0.1:6767): the New Session page's controls answer taps, and the sidebar's server
/// menu can leave a no-auth server for the server list and come back.
///
/// Set `TEST_RUNNER_PHONE_SHOTS_DIR` to also write each state as `pad-<state>.png` there.
final class PadShellUITests: XCTestCase {
  private var server: String {
    ProcessInfo.processInfo.environment["OMNIGENT_SERVER"] ?? "http://127.0.0.1:6767"
  }

  @MainActor
  func testNewSessionControlsAnswerTaps() throws {
    let app = try launchPad()
    let newSession = app.descendants(matching: .any)["sidebar-new-session"].firstMatch
    XCTAssertTrue(newSession.waitForExistence(timeout: 30), "the server did not connect")
    newSession.tap()

    let approval = app.descendants(matching: .any)["composer-approval-mode"].firstMatch
    XCTAssertTrue(approval.waitForExistence(timeout: 15), "no approval chip")
    approval.tap()
    let mode = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'composer-approval-mode-'")).firstMatch
    XCTAssertTrue(mode.waitForExistence(timeout: 5), "the approval menu did not open")
    try shot(app, "approval-menu")
    dismissMenu(app)

    let agents = app.descendants(matching: .any)["composer-configuration"].firstMatch
    XCTAssertTrue(agents.waitForExistence(timeout: 5), "no agent picker")
    agents.tap()
    let agent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'composer-agent-'")).firstMatch
    XCTAssertTrue(agent.waitForExistence(timeout: 5), "the agent picker did not open")
    try shot(app, "agent-picker")
    dismissMenu(app)

    let setUp = app.buttons["new-session-harness-setup"]
    if setUp.exists {
      setUp.tap()
      let sheet = app.descendants(matching: .any)["harness-setup-sheet"].firstMatch
      XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Set Up did not open its sheet")
      try shot(app, "harness-setup")
    }
  }

  @MainActor
  func testServerMenuLeavesAndReturnsToANoAuthServer() throws {
    let app = try launchPad()
    let switcher = app.descendants(matching: .any)["server-switcher"].firstMatch
    XCTAssertTrue(switcher.waitForExistence(timeout: 30), "the server did not connect")
    switcher.tap()
    let connectNew = app.buttons["Connect to New Server\u{2026}"]
    XCTAssertTrue(connectNew.waitForExistence(timeout: 5), "no Connect to New Server item")
    try shot(app, "server-menu")
    connectNew.tap()

    // The server list, with the server just left among the recents.
    let connect = app.buttons["auth.connect"]
    XCTAssertTrue(connect.waitForExistence(timeout: 10), "the server list did not show")
    try shot(app, "server-list")
    let recent = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS '127.0.0.1'")).firstMatch
    XCTAssertTrue(recent.waitForExistence(timeout: 5), "the server left is not a recent")
    recent.tap()
    XCTAssertTrue(switcher.waitForExistence(timeout: 30), "did not reconnect from the recents")
  }

  @MainActor
  func testDeepLinkOpensTheSessionAndPairingCodesStillConfirm() throws {
    // iPhone and the folded Duo too: links are not iPad-only.
    let app = try launchPad(padOnly: false)
    let switcher = app.descendants(matching: .any)["server-switcher"].firstMatch
    XCTAssertTrue(switcher.waitForExistence(timeout: 30), "the server did not connect")
    let sessionID =
      ProcessInfo.processInfo.environment["OMNIGENT_SESSION"]
      ?? "efb05e5b065c42f78ff2271c7c97fa9b"
    let host = try XCTUnwrap(URL(string: server)?.host(), "no host in \(server)")
    let port = URL(string: server)?.port.map { ":\($0)" } ?? ""
    try openURL("omnigent://\(host)\(port)/c/\(sessionID)")
    let transcript = app.descendants(matching: .any)["transcript-\(sessionID)"].firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 20), "the link did not open the session")
    try shot(app, "deep-link")

    let encoded = try XCTUnwrap(
      server.addingPercentEncoding(withAllowedCharacters: .alphanumerics), "unencodable server")
    try openURL("omnigent:pair?v=1&server=\(encoded)")
    let pairing = app.descendants(matching: .any)["pairing.host"].firstMatch
    XCTAssertTrue(pairing.waitForExistence(timeout: 10), "the pairing code was not confirmed")
    try shot(app, "pairing")
  }

  // MARK: Helpers

  /// Opens `link` as the system does, accepting its "Open in" prompt.
  @MainActor
  private func openURL(_ link: String) throws {
    XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: link), "bad link \(link)"))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons["Open"]
    if open.waitForExistence(timeout: 5) { open.tap() }
  }

  /// The app on the local server; iPad only unless `padOnly` is false.
  @MainActor
  private func launchPad(padOnly: Bool = true) throws -> XCUIApplication {
    let isPad = UIDevice.current.userInterfaceIdiom == .pad
    if padOnly, !isPad { throw XCTSkip("iPad layout only") }
    // A first launch asks for notifications; the prompt would cover the sidebar.
    addUIInterruptionMonitor(withDescription: "Notifications") { alert in
      let decline = alert.buttons["Don\u{2019}t Allow"]
      guard decline.exists else { return false }
      decline.tap()
      return true
    }
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
    ]
    app.launch()
    XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    return app
  }

  /// Closes an open menu by tapping outside it, near the window's bottom-trailing corner.
  @MainActor
  private func dismissMenu(_ app: XCUIApplication) {
    app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = state
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["PHONE_SHOTS_DIR"] else { return }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("pad-\(state).png"))
  }
}
