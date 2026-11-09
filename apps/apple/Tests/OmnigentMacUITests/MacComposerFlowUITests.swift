import AppKit
import XCTest

/// Sending from the composer on the offline demo server: follow-ups, stopping a turn, queueing,
/// attachments, and the model and mode chips. A message with "in detail" gets the long reply.
final class MacComposerFlowUITests: XCTestCase {
  /// The longest a long demo reply takes to finish.
  private let turnTimeout: TimeInterval = 240

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A follow-up shows in the transcript, empties the composer and gets a reply of its own.
  @MainActor
  func testFollowUpMessageGetsItsOwnReply() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)
    let replies = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'message-' AND identifier CONTAINS '-reply-'"))
    let before = replies.count

    let followUp = "Follow up \(UUID().uuidString.prefix(6))"
    live.send(followUp, in: app)
    live.assertShows(followUp, in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 60) { replies.count > before }, "the follow-up got no reply")
  }

  /// Return sends, with the default setting, as Command-Return does.
  @MainActor
  func testReturnSendsAMessage() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    let message = "Sent with Return \(UUID().uuidString.prefix(6))"
    live.click(live.composer(in: app), "the composer")
    app.typeText(message + "\r")
    live.assertShows(message, in: app)
  }

  /// The Stop button ends a reply partway, and the transcript says it stopped.
  @MainActor
  func testStopButtonEndsTheTurnMidReply() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startDemoSession("Explain the plan in detail", in: app)

    let stop = live.element("composer-stop", in: app)
    live.click(stop, "Stop", timeout: 15)
    XCTAssertTrue(stop.waitForNonExistence(timeout: 15), "Stop did not end the turn")
    XCTAssertTrue(
      live.text(containing: "Reply stopped.", in: app).waitForExistence(timeout: 15),
      "the transcript does not say the reply stopped")
  }

  /// A message queued during a turn waits above the composer, then sends when the turn ends.
  @MainActor
  func testMessageQueuedWhileRunningSendsAfterTheTurn() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startDemoSession("Summarize the open questions in detail", in: app)
    let stop = live.element("composer-stop", in: app)
    XCTAssertTrue(stop.waitForExistence(timeout: 15), "no turn ran")

    let message = "Queued \(UUID().uuidString.prefix(6))"
    live.click(live.composer(in: app), "the composer")
    app.typeText(message)
    let send = live.element("composer-send", in: app)
    if send.label == "Queue after this turn" {
      send.click()
    } else {
      // Sending steers this agent; the alternative send is the queue.
      app.typeKey(.return, modifierFlags: [.command, .option])
    }
    let queued = live.elements(prefix: "queued-", in: app).firstMatch
    XCTAssertTrue(queued.waitForExistence(timeout: 10), "the message did not join the queue")
    XCTAssertFalse(live.composerText(in: app).contains(message), "it stayed in the composer")

    XCTAssertTrue(queued.waitForNonExistence(timeout: turnTimeout), "the queue never sent it")
    XCTAssertTrue(
      live.text(containing: message, in: app).waitForExistence(timeout: 15),
      "the queued message is not in the transcript")
  }

  /// A file pasted into the composer shows as a chip, and sending carries it into the transcript.
  @MainActor
  func testPastedFileAttachesAndSends() throws {
    let live = MacLiveUITestSupport(self)
    let file = try live.writeTextFile(named: "pasted-flow.txt")
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(file.absoluteString, forType: .fileURL)
    live.click(live.composer(in: app), "the composer")
    app.typeKey("v", modifierFlags: .command)
    let chip = live.elements(prefix: "draft-attachment-", in: app).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the pasted file is not attached")

    app.typeText("With the pasted file")
    app.typeKey(.return, modifierFlags: .command)
    XCTAssertTrue(chip.waitForNonExistence(timeout: 15), "the chip stayed after sending")
    XCTAssertTrue(
      live.elements(prefix: "attachment-", in: app).firstMatch.waitForExistence(timeout: 15),
      "the sent message has no attachment")
  }

  /// The Add menu's file panel attaches the chosen file, and its chip can be removed.
  @MainActor
  func testAddMenuAttachesAFileAndItsChipRemovesIt() throws {
    let live = MacLiveUITestSupport(self)
    let file = try live.writeTextFile(named: "chosen-flow.txt")
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    live.click(live.element("composer-add", in: app), "the Add menu")
    live.clickMenuItem("Files and images", in: app)
    // The open panel: Go to Folder, the file's path, then Open.
    XCTAssertTrue(
      app.sheets.firstMatch.waitForExistence(timeout: 15) || app.dialogs.firstMatch.exists,
      "no open panel")
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(file.path + "\r")
    live.clickDialogButton("Open", in: app)

    let chip = live.elements(prefix: "draft-attachment-", in: app).firstMatch
    XCTAssertTrue(chip.waitForExistence(timeout: 15), "the chosen file is not attached")
    let remove = live.elements(prefix: "draft-attachment-remove-", in: app).firstMatch
    remove.click()
    XCTAssertTrue(chip.waitForNonExistence(timeout: 10), "the chip stayed after Remove")
  }

  /// The model chip switches the session's model.
  @MainActor
  func testModelChipSwitchesTheModel() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    let chip = live.element("composer-configuration", in: app)
    live.click(chip, "the model chip")
    live.clickMenuItem("Sample Fast", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { chip.label.contains("Sample Fast") },
      "the chip still says \(chip.label)")
  }

  /// The mode chip switches a running session's approval mode.
  @MainActor
  func testModeChipSwitchesTheApprovalMode() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    let chip = live.element("composer-approval-mode", in: app)
    live.click(chip, "the mode chip")
    live.clickMenuItem("Full access", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { chip.label.contains("Full access") },
      "the chip still says \(chip.label)")
  }

  /// Shift-Tab in the composer moves to the next approval mode.
  @MainActor
  func testShiftTabCyclesTheMode() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)
    let chip = live.element("composer-approval-mode", in: app)
    XCTAssertTrue(chip.waitForExistence(timeout: 10), "no mode chip")
    let before = chip.label

    live.click(live.composer(in: app), "the composer")
    app.typeKey(.tab, modifierFlags: .shift)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { chip.label != before }, "Shift-Tab left the mode at \(before)")
  }
}
