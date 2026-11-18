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

  /// A follow-up shows in the transcript with the session working at once, empties the composer
  /// and gets a reply of its own.
  @MainActor
  func testFollowUpMessageGetsItsOwnReply() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)
    let replies = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'message-' AND identifier CONTAINS '-reply-'"))
    let before = replies.count
    let working = live.element("transcript-working", in: app)
    XCTAssertTrue(working.disappears(within: 15), "the stopped reply still shows working")

    let followUp = "Follow up \(UUID().uuidString.prefix(6))"
    live.send(followUp, in: app)
    XCTAssertTrue(working.appears(within: 3), "Working did not show right after sending")
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
    live.focusComposer(in: app)
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
    XCTAssertTrue(stop.disappears(within: 15), "Stop did not end the turn")
    XCTAssertTrue(
      live.text(containing: "Reply stopped.", in: app).appears(within: 15),
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
    XCTAssertTrue(stop.appears(within: 15), "no turn ran")

    let message = "Queued \(UUID().uuidString.prefix(6))"
    live.focusComposer(in: app)
    app.typeText(message)
    let send = live.element("composer-send", in: app)
    if send.label == "Queue after this turn" {
      send.click()
    } else {
      // Sending steers this agent; the alternative send is the queue.
      app.typeKey(.return, modifierFlags: [.command, .option])
    }
    let queued = live.elements(prefix: "queued-", in: app).firstMatch
    XCTAssertTrue(queued.appears(within: 10), "the message did not join the queue")
    XCTAssertFalse(live.composerText(in: app).contains(message), "it stayed in the composer")

    XCTAssertTrue(queued.disappears(within: turnTimeout), "the queue never sent it")
    XCTAssertTrue(
      live.text(containing: message, in: app).appears(within: 15),
      "the queued message is not in the transcript")
  }

  /// An image pasted into the composer shows as a chip, and sending carries it into the
  /// transcript. Command-V attaches images only; other files paste as their path.
  @MainActor
  func testPastedImageAttachesAndSends() throws {
    let live = MacLiveUITestSupport(self)
    let image = try XCTUnwrap(Self.pngSquare(), "could not draw an image to paste")
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    NSPasteboard.general.clearContents()
    XCTAssertTrue(NSPasteboard.general.setData(image, forType: .png), "the pasteboard refused it")
    live.focusComposer(in: app)
    app.typeKey("v", modifierFlags: .command)
    let chip = live.elements(prefix: "draft-attachment-", in: app).firstMatch
    XCTAssertTrue(chip.appears(within: 15), "the pasted image is not attached")

    app.typeText("With the pasted image")
    app.typeKey(.return, modifierFlags: .command)
    XCTAssertTrue(chip.disappears(within: 15), "the chip stayed after sending")
    XCTAssertTrue(
      live.elements(prefix: "attachment-", in: app).firstMatch.appears(within: 15),
      "the sent message has no attachment")
  }

  /// A small opaque square as PNG data.
  private static func pngSquare() -> Data? {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      NSColor.systemTeal.setFill()
      rect.fill()
      return true
    }
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
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
      app.sheets.firstMatch.appears(within: 15) || app.dialogs.firstMatch.exists,
      "no open panel")
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(file.path + "\r")
    live.clickDialogButton("Open", in: app)

    let chip = live.elements(prefix: "draft-attachment-", in: app).firstMatch
    XCTAssertTrue(chip.appears(within: 15), "the chosen file is not attached")
    let remove = live.elements(prefix: "draft-attachment-remove-", in: app).firstMatch
    remove.click()
    XCTAssertTrue(chip.disappears(within: 10), "the chip stayed after Remove")
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
    // The demo's default agent runs Claude Code, whose modes are these.
    live.clickMenuItem("Auto-edit", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { chip.label.contains("Auto-edit") },
      "the chip still says \(chip.label)")
  }

  /// Edit and resend on a sent message puts its text in the composer, asking first when a
  /// draft is there; sending it is a new message, and the original stays.
  @MainActor
  func testEditAndResendASentMessage() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)
    let original = "Original \(UUID().uuidString.prefix(6))"
    live.send(original, in: app)
    live.assertShows(original, in: app)
    XCTAssertTrue(
      live.element("composer-stop", in: app).disappears(within: 60), "the reply did not end")

    live.focusComposer(in: app)
    app.typeText("a draft in progress")
    // The newest prompt's cell (`message-<item id>`; the demo's prompts are `<session>-user-<n>`).
    let prompts = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'message-demo-session-' AND identifier CONTAINS '-user-'"))
    let prompt = live.hittable(prompts, timeout: 15)
    XCTAssertNotNil(prompt, "no prompt cell\n\(app.debugDescription)")
    prompt?.rightClick()
    let edit = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'Edit and Resend'"))
    guard let item = live.hittable(edit) else {
      let titles = app.menuItems.allElementsBoundByIndex.map(\.title)
      XCTFail("the message menu has no Edit and Resend: \(titles)")
      return
    }
    item.click()
    live.clickDialogButton("Replace draft", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 10) { live.composerText(in: app) == original },
      "the composer holds \(live.composerText(in: app))")

    app.typeText(" edited")
    app.typeKey(.return, modifierFlags: .command)
    live.assertShows("\(original) edited", in: app)
    XCTAssertTrue(
      live.text(containing: original, in: app).exists, "the original message is gone")
  }

  /// `/rewind` in a Claude session lists its prompts; choosing one opens a new session holding
  /// the history before it, with the prompt back in the composer.
  @MainActor
  func testRewindContinuesFromAnEarlierPrompt() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openNewSession(in: app)
    let chip = live.element("composer-configuration", in: app)
    if !chip.label.contains("Sample Claude") {
      live.click(chip, "the agent picker")
      live.clickMenuItem("Sample Claude", in: app)
      XCTAssertTrue(
        live.waitUntil { chip.label.contains("Sample Claude") }, "the form shows \(chip.label)")
    }
    let tag = UUID().uuidString.prefix(6)
    let stop = live.element("composer-stop", in: app)
    for prompt in ["First \(tag)", "Second \(tag)"] {
      live.send(prompt, in: app)
      live.assertShows(prompt, in: app)
      XCTAssertTrue(stop.disappears(within: 60), "the reply to \(prompt) did not end")
    }

    live.send("/rewind", in: app)
    let picker = live.element("rewind-picker", in: app)
    XCTAssertTrue(picker.appears(within: 15), "/rewind opened no picker")
    XCTAssertTrue(
      live.text(containing: "First \(tag)", in: app).appears(within: 15), "no prompts listed")
    app.typeText("Second")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(picker.disappears(within: 15), "the picker stayed open")
    XCTAssertTrue(
      live.waitUntil(timeout: 20) { live.composerText(in: app) == "Second \(tag)" },
      "the rewound session's composer holds \(live.composerText(in: app))")
    XCTAssertTrue(
      live.text(containing: "First \(tag)", in: app).appears(within: 15),
      "the rewound session lost the earlier history")
  }

  /// Shift-Tab in the composer moves to the next approval mode.
  @MainActor
  func testShiftTabCyclesTheMode() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)
    let chip = live.element("composer-approval-mode", in: app)
    // A new session reports no mode yet, and Shift-Tab only moves on from a known one.
    live.click(chip, "the mode chip")
    live.clickMenuItem("Auto-edit", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { chip.label.contains("Auto-edit") },
      "the chip still says \(chip.label)")
    let before = chip.label

    live.focusComposer(in: app)
    app.typeKey(.tab, modifierFlags: .shift)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { chip.label != before }, "Shift-Tab left the mode at \(before)")
  }
}
