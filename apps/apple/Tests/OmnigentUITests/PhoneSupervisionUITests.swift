import XCTest

/// Phone supervision against the offline demo: backgrounding posts one actionable notification
/// per pending request, Approve answers the approval, and Reply answers the question, without
/// opening the app. Set `TEST_RUNNER_SUPERVISION_SHOTS_DIR` to also write screenshots there.
final class PhoneSupervisionUITests: XCTestCase {
  @MainActor private var springboard: XCUIApplication {
    XCUIApplication(bundleIdentifier: "com.apple.springboard")
  }

  @MainActor
  func testApproveAndReplyFromNotifications() throws {
    let app = XCUIApplication()
    // An empty notified-request ledger, so the demo's requests notify again on every run.
    app.launchArguments += [
      "-OmnigentDemo", "-omnigent.lastServer", "http://127.0.0.1:6767",
      "-omnigent.supervision.ledger", "()",
    ]
    app.launch()
    let allow = springboard.buttons["Allow"]
    // Asked once per install; the prompt can take a while on a busy simulator.
    if allow.waitForExistence(timeout: 45) {
      allow.tap()
      XCTAssertTrue(allow.waitForNonExistence(timeout: 30))
    }
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))

    // Backgrounding sweeps what needs the user: the approval and the question.
    XCUIDevice.shared.press(.home)
    let approval = notification(containing: "Native mobile design")
    XCTAssertTrue(approval.waitForExistence(timeout: 60), "No approval notification")
    try shot("banner")
    // Long-press the banner while it shows to reveal its actions.
    approval.press(forDuration: 1.5)
    let approve = springboard.buttons["Approve"]
    XCTAssertTrue(approve.waitForExistence(timeout: 10), "No Approve action")
    XCTAssertTrue(springboard.buttons["Deny"].exists)
    try shot("approval-actions")
    approve.tap()

    try replyToQuestion(with: "2")

    // Both requests were answered from the notifications.
    app.activate()
    let design = app.descendants(matching: .any).matching(identifier: "session-row-demo-design")
      .firstMatch
    let release = app.descendants(matching: .any).matching(identifier: "session-row-demo-question")
      .firstMatch
    // A restored scene may open on a session; go back to the list.
    for _ in 0..<3 where !design.waitForExistence(timeout: 5) {
      let back = app.navigationBars.buttons.firstMatch
      if back.exists { back.tap() }
    }
    XCTAssertTrue(design.exists)
    XCTAssertTrue(
      waitUntil(timeout: 20) {
        !design.label.contains("Needs you") && !release.label.contains("Needs you")
      }, "Still needs you: \(design.label) / \(release.label)")
    try shot("answered")
  }

  /// Answers the demo's question from Notification Center with `text`.
  @MainActor
  private func replyToQuestion(with text: String) throws {
    let question = notification(containing: "Choose the first release")
    for _ in 0..<3 where !question.waitForExistence(timeout: 3) { openNotificationCenter() }
    XCTAssertTrue(question.exists, "No question notification")
    try shot("notification-center")
    question.press(forDuration: 1.5)
    // Reply is the only action, so the system opens its text field directly.
    if !springboard.keyboards.firstMatch.waitForExistence(timeout: 5) {
      let reply = springboard.buttons["Reply"]
      XCTAssertTrue(reply.waitForExistence(timeout: 10), "No Reply action")
      reply.tap()
    }
    let keyboardTip = springboard.buttons["Continue"]
    if keyboardTip.exists { keyboardTip.tap() }
    springboard.typeText(text)
    try shot("question-reply")
    springboard.buttons["Send"].tap()
  }

  @MainActor
  private func notification(containing text: String) -> XCUIElement {
    springboard.descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
  }

  @MainActor
  private func openNotificationCenter() {
    let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0))
    let middle = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.7))
    top.press(forDuration: 0.05, thenDragTo: middle, withVelocity: .slow, thenHoldForDuration: 0.2)
  }

  @MainActor
  private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    return condition()
  }

  @MainActor
  private func shot(_ name: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = ProcessInfo.processInfo.environment["SUPERVISION_SHOTS_DIR"] else {
      return
    }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("r3-notify-\(name).png"))
  }
}
