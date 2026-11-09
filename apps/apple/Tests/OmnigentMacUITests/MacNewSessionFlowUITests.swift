import XCTest

/// Starting a session on the offline demo server: the form takes the keyboard, its agent, folder
/// and approval choices reach the session, and the first message shows at once and gets a reply.
final class MacNewSessionFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Command-N opens the form with the composer focused: typing needs no click.
  @MainActor
  func testNewSessionFormTakesTheKeyboard() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openNewSession(in: app)

    let typed = "typed without a click"
    app.typeText(typed)
    XCTAssertTrue(
      live.waitUntil { live.composerText(in: app).contains(typed) },
      "the composer did not take the keyboard: \(live.composerText(in: app))")
  }

  /// The sidebar's New session row opens the same form.
  @MainActor
  func testSidebarRowOpensTheForm() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    live.click(live.element("sidebar-new-session", in: app), "New session")
    XCTAssertTrue(
      live.element("new-session-page", in: app).waitForExistence(timeout: 10), "no form")
    XCTAssertTrue(live.composer(in: app).waitForExistence(timeout: 10), "the form has no composer")
  }

  /// The form cannot start without a message.
  @MainActor
  func testEmptyFormCannotStart() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openNewSession(in: app)

    app.typeKey(.return, modifierFlags: .command)
    XCTAssertFalse(
      live.anyTranscript(in: app).waitForExistence(timeout: 3), "an empty form started a session")
    XCTAssertTrue(live.element("new-session-page", in: app).exists, "the form went away")
  }

  /// The chosen agent is the one the new session runs.
  @MainActor
  func testChosenAgentIsWhatTheSessionUses() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openNewSession(in: app)

    chooseClaude(live, app)
    live.send("Which agent is this?", in: app)
    XCTAssertTrue(
      live.anyTranscript(in: app).waitForExistence(timeout: 15), "the session did not start")
    let chip = live.element("composer-configuration", in: app)
    XCTAssertTrue(
      live.waitUntil { chip.label.contains("Sample Claude") }, "the session runs \(chip.label)")
  }

  /// Browse Folders chooses the folder the session works in.
  @MainActor
  func testFolderBrowserSetsTheFolder() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openNewSession(in: app)

    let chip = live.element("new-session-folder", in: app)
    live.click(chip, "the folder chip")
    live.clickMenuItem("Browse Folders\u{2026}", in: app)
    let choose = live.element("folder-browser-choose", in: app)
    XCTAssertTrue(choose.waitForExistence(timeout: 10), "the folder browser did not open")
    live.click(live.element("folder-browser-row-demo", in: app), "the demo folder")
    XCTAssertTrue(live.waitUntil { choose.isEnabled }, "the browser offers no folder to choose")
    choose.click()
    XCTAssertTrue(choose.waitForNonExistence(timeout: 10), "Choose left the browser open")
    XCTAssertTrue(
      live.waitUntil { chip.label.contains("demo") }, "the chip still says \(chip.label)")
  }

  /// The approval mode chosen on the form is the mode the session then reports.
  @MainActor
  func testChosenApprovalModeIsWhatTheSessionUses() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openNewSession(in: app)
    chooseClaude(live, app)

    let chip = live.element("composer-approval-mode", in: app)
    live.click(chip, "the approval chip")
    live.clickMenuItem("Auto-edit", in: app)
    XCTAssertTrue(
      live.waitUntil { chip.label.contains("Auto-edit") }, "the form shows \(chip.label)")
    live.send("Use the mode I chose", in: app)
    XCTAssertTrue(
      live.anyTranscript(in: app).waitForExistence(timeout: 15), "the session did not start")
    XCTAssertTrue(
      live.waitUntil { chip.exists && chip.label.contains("Auto-edit") },
      "the session runs \(chip.label), not the chosen mode")
  }

  /// The first message shows at once, then the reply arrives and the turn ends.
  @MainActor
  func testFirstMessageShowsAtOnceAndTheReplyArrives() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let message = "First message \(UUID().uuidString.prefix(6))"

    live.startDemoSession(message, in: app)
    live.assertShows(message, in: app, timeout: 5)
    XCTAssertTrue(
      live.text(containing: "sample reply", in: app).waitForExistence(timeout: 60),
      "the reply never arrived")
    XCTAssertTrue(
      live.element("composer-stop", in: app).waitForNonExistence(timeout: 60),
      "the turn did not end")
  }

  /// Picks the demo's Claude agent, whose modes a session reports back.
  @MainActor
  private func chooseClaude(_ live: MacLiveUITestSupport, _ app: XCUIApplication) {
    let chip = live.element("composer-configuration", in: app)
    live.click(chip, "the agent picker")
    live.clickMenuItem("Sample Claude", in: app)
    XCTAssertTrue(
      live.waitUntil { chip.label.contains("Sample Claude") }, "the form shows \(chip.label)")
  }
}
