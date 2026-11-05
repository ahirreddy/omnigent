import UIKit
import XCTest

/// The composer's queue and reply quotes against the offline demo server: a message queued with
/// a photo while a turn runs shows the file in the queue and sends it after the turn, and Reply
/// quotes a message as a removable block that is sent as a block quote.
///
/// The queue test picks the newest photo; add one with `xcrun simctl addmedia`.
///
/// Set `TEST_RUNNER_PHONE_SHOTS_DIR` to also write each state as `<prefix>-<style>-<state>.png`
/// there (prefix from `TEST_RUNNER_PHONE_SHOTS_PREFIX`).
final class ComposerQueueUITests: XCTestCase {
  /// The longest a demo reply takes to finish.
  private let turnTimeout: TimeInterval = 240

  @MainActor
  func testQueuedMessageCarriesAPhotoAndSendsAfterTheTurn() throws {
    try skipOnPad()
    let app = launch(style: "chat")
    // The demo streams a long reply when asked for detail, leaving time to queue.
    let input = try startSession(
      in: app, prompt: "Summarize the open questions in detail", warmPhotoPicker: true)
    XCTAssertTrue(app.buttons["composer-stop"].waitForExistence(timeout: 15), "no turn ran")
    try attachPhoto(in: app)
    let chip = element(app, prefix: "draft-attachment-")
    XCTAssertTrue(chip.waitForExistence(timeout: 30), "the photo was not attached")
    input.tap()
    input.typeText("and this photo")
    try queue(in: app)
    let queued = element(app, prefix: "queued-attachments-")
    XCTAssertTrue(queued.waitForExistence(timeout: 10), "the queued message lost its file")
    XCTAssertFalse(chip.exists, "the file stayed in the composer")
    try shot(app, "chat", "queued-with-attachment")
    // The turn ends, then the queue sends the message with its file.
    XCTAssertTrue(app.buttons["composer-stop"].waitForNonExistence(timeout: turnTimeout))
    XCTAssertTrue(queued.waitForNonExistence(timeout: 30), "the queued message was not sent")
    let sent = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS 'and this photo'")
    ).firstMatch
    XCTAssertTrue(sent.waitForExistence(timeout: 15), "the sent message is not in the transcript")
    let sentFile = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'attachment-'")).firstMatch
    XCTAssertTrue(sentFile.waitForExistence(timeout: 10), "the sent message has no file")
    try shot(app, "chat", "queued-sent")
  }

  @MainActor
  func testReplyQuotesAMessageAsABlock() throws {
    try skipOnPad()
    for style in ["chat", "cli"] {
      let app = launch(style: style)
      let input = try startSession(in: app, prompt: "Summarize the open questions")
      XCTAssertTrue(app.buttons["composer-stop"].waitForNonExistence(timeout: turnTimeout))
      let reply = app.descendants(matching: .any)
        .matching(
          NSPredicate(format: "identifier BEGINSWITH 'message-' AND identifier CONTAINS '-reply-'")
        )
        .firstMatch
      XCTAssertTrue(reply.waitForExistence(timeout: 10), "\(style): no reply")
      reply.press(forDuration: 1.2)
      let replyAction = app.buttons["Reply"].firstMatch
      XCTAssertTrue(replyAction.waitForExistence(timeout: 5), "\(style): no Reply action")
      replyAction.tap()
      let quote = app.descendants(matching: .any)["composer-quote-0"]
      XCTAssertTrue(quote.waitForExistence(timeout: 5), "\(style): no quote block")
      XCTAssertTrue(app.buttons["composer-quote-remove-0"].exists, "\(style): no Remove quote")
      input.tap()
      input.typeText("Which one first?")
      try shot(app, style, "quote-in-composer")
      app.buttons["composer-send"].tap()
      XCTAssertTrue(quote.waitForNonExistence(timeout: 10), "\(style): the quote stayed")
      let sent = app.descendants(matching: .any)
        .matching(NSPredicate(format: "label CONTAINS 'Which one first?'")).firstMatch
      XCTAssertTrue(sent.waitForExistence(timeout: 15), "\(style): the reply was not sent")
      // Show the end, where the sent quote is.
      let latest = app.buttons["Jump to latest"].firstMatch
      if latest.waitForExistence(timeout: 2) { latest.tap() }
      sleep(1)
      try shot(app, style, "quote-sent")
      app.terminate()
    }
  }

  // MARK: Helpers

  /// The iPad keeps the previous session's composer under New Session, so these single-composer
  /// queries are phone-only.
  private func skipOnPad() throws {
    try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "expects one composer on screen")
  }

  @MainActor
  private func launch(style: String) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments += [
      "-OmnigentDemo", "-ApplePersistenceIgnoreState", "YES",
      "-omnigent:transcript-style", style,
    ]
    app.launch()
    XCUIDevice.shared.orientation = .portrait
    return app
  }

  /// Opens New Session and sends `prompt`; returns the composer's field. `warmPhotoPicker` first
  /// opens and cancels the photo picker, whose first load is slower than a demo turn.
  @MainActor
  private func startSession(
    in app: XCUIApplication, prompt: String, warmPhotoPicker: Bool = false
  ) throws -> XCUIElement {
    let newSession = app.descendants(matching: .any)["sidebar-new-session"].firstMatch
    for _ in 0..<3 where !newSession.waitForExistence(timeout: 8) {
      let back = app.navigationBars.buttons["BackButton"]
      guard back.exists else { break }
      back.tap()
    }
    newSession.tap()
    let input = app.textViews["composer-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    if warmPhotoPicker {
      _ = try openPhotoPicker(in: app)
      app.buttons["Cancel"].firstMatch.tap()
    }
    input.tap()
    input.typeText(prompt)
    app.buttons["composer-send"].tap()
    XCTAssertTrue(
      element(app, prefix: "message-").waitForExistence(timeout: 15), "the session did not start")
    return input
  }

  /// Adds the library's newest photo from the composer's Add menu.
  @MainActor
  private func attachPhoto(in app: XCUIApplication) throws {
    try openPhotoPicker(in: app).tap()
    // The picker's Done; the composer's own Add button sits behind the sheet.
    app.buttons.matching(NSPredicate(format: "identifier == 'Add' AND label == 'Done'")).firstMatch
      .tap()
  }

  /// Opens the photo picker from the Add menu; returns its newest photo once it has loaded.
  @MainActor
  private func openPhotoPicker(in app: XCUIApplication) throws -> XCUIElement {
    app.buttons["composer-add"].tap()
    let photos = app.buttons["Photos\u{2026}"].firstMatch
    XCTAssertTrue(photos.waitForExistence(timeout: 5), "no Photos in the Add menu")
    photos.tap()
    let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo'")).firstMatch
    XCTAssertTrue(photo.waitForExistence(timeout: 90), "the photo library is empty")
    return photo
  }

  /// Queues the draft: Send queues once something is queued; otherwise its menu does.
  @MainActor
  private func queue(in app: XCUIApplication) throws {
    let send = app.buttons["composer-send"]
    if send.label != "Queue after this turn" {
      send.press(forDuration: 1.2)
      let queueAction = app.buttons.matching(
        NSPredicate(format: "label BEGINSWITH 'Queued' OR label BEGINSWITH 'Send after'")
      ).firstMatch
      if !queueAction.waitForExistence(timeout: 5) { try shot(app, "chat", "no-queue-choice") }
      XCTAssertTrue(queueAction.exists, "no queue choice")
      // Let the menu finish appearing so the item is hittable.
      sleep(1)
      queueAction.tap()
    } else {
      send.tap()
    }
  }

  private func element(_ app: XCUIApplication, prefix: String) -> XCUIElement {
    app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
  }

  @MainActor
  private func shot(_ app: XCUIApplication, _ style: String, _ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(style)-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["PHONE_SHOTS_DIR"] else { return }
    let prefix = environment["PHONE_SHOTS_PREFIX"] ?? "composer"
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)-\(style)-\(state).png"))
  }
}
