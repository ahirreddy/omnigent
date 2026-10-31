import XCTest

@MainActor
final class NativeEventUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--ui-test-event-gallery", "--reset-demo"]
    app.launch()
    tap("open-demo")
  }

  override func tearDownWithError() throws {
    app.terminate()
    app = nil
  }

  func testRoutineLifecycleStaysInActivityAndFailureIsCompact() {
    open("gallery-lifecycle")
    XCTAssertFalse(app.buttons["activity-toggle-lifecycle-created"].exists)
    XCTAssertFalse(app.buttons["activity-toggle-lifecycle-deleted"].exists)
    XCTAssertTrue(element("message-stopped-lifecycle-reply").exists)
    let failure = app.buttons["provider-failure-gallery-lifecycle"]
    XCTAssertTrue(failure.exists)
    XCTAssertEqual(failure.value as? String, "Collapsed")
    XCTAssertLessThan(failure.frame.height, 80)
    XCTAssertFalse(app.buttons["failure-review-gallery-lifecycle"].exists)
    capture("hierarchy-quiet-conversation")
    tap("provider-failure-gallery-lifecycle")
    tap("failure-review-gallery-lifecycle")
    tap("lifecycle-history")
    tap("activity-toggle-lifecycle-deleted")
    XCTAssertEqual(element("activity-detail-lifecycle-deleted-id").label, "fixture-terminal")
    capture("hierarchy-lifecycle-details")
    tap("session-activity-done")
    XCTAssertTrue(element("message-stopped-lifecycle-reply").exists)
    XCTAssertTrue(app.buttons["composer-configuration"].exists)
  }

  func testActivityDetailsRemainReadableAndDisplayOnly() {
    open("gallery-activities")
    tap("activity-toggle-gallery-unknown", direction: .down)
    XCTAssertTrue(
      element("activity-detail-gallery-unknown-details").label.contains(
        "Useful future event detail"))
    XCTAssertTrue(app.buttons["activity-copy-gallery-unknown-details"].exists)
    capture("events-unknown-details")
    tap("activity-toggle-gallery-unknown", direction: .down)
    tap("activity-toggle-gallery-terminal", direction: .up)
    XCTAssertTrue(
      element("activity-detail-gallery-terminal-details").label.contains("BUILD SUCCEEDED"))
    XCTAssertTrue(app.staticTexts["Recorded activity only. No action runs on this device."].exists)
    capture("events-terminal-details")
    tap("activity-toggle-gallery-terminal", direction: .up)
    tap("activity-toggle-gallery-toolCall", direction: .up)
    XCTAssertTrue(
      element("activity-detail-gallery-toolCall-details").label.contains("ConversationView"))
    capture("events-tool-details")
  }

  func testAttachmentsHaveNativeDescriptorsWithoutAutomaticDownload() {
    open("gallery-attachments")
    tap("attachment-gallery-image", direction: .up)
    XCTAssertEqual(
      element("attachment-reference-gallery-image").label, "https://example.invalid/design.png")
    XCTAssertTrue(app.staticTexts["Attachment reference. Not downloaded to this device."].exists)
    XCTAssertTrue(app.state == .runningForeground)
    capture("events-image-attachment")
    tap("attachment-gallery-image", direction: .up)
    tap("attachment-gallery-file", direction: .down)
    XCTAssertEqual(element("attachment-reference-gallery-file").label, "file-gallery-contract")
    capture("events-file-attachment")
    tap("attachment-preview-gallery-file")
    let close = app.buttons["QLOverlayDoneButtonAccessibilityIdentifier"].firstMatch
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.textViews["Native attachment preview fixture. No server request was made."]
        .waitForExistence(timeout: 5))
    capture("events-native-file-preview")
    close.tap()
    XCTAssertTrue(element("conversation-gallery-attachments").waitForExistence(timeout: 5))
  }

  func testTypedRequestRequiresExplicitBooleanAndValidNumber() {
    open("gallery-form")
    tap("request-form-open-gallery-form-request")
    XCTAssertFalse(app.buttons["request-form-submit"].isEnabled)
    enter("Omni", field: "name")
    enter("2", field: "count")
    tap("request-hide-keyboard")
    tap("request-boolean-notify-no", direction: .down)
    let submit = app.buttons["request-form-submit"]
    XCTAssertTrue(submit.isEnabled)
    capture("events-typed-request")
    submit.tap()
    XCTAssertTrue(element("decision-status-gallery-form-request").waitForExistence(timeout: 5))
    XCTAssertEqual(element("decision-status-gallery-form-request").label, "Answers submitted")
    XCTAssertFalse(app.buttons["request-form-submit"].exists)
  }

  func testStructuredQuestionsPreserveSelectionsAcrossDismissal() {
    open("gallery-question")
    tap("request-form-open-gallery-question-request")
    tap("request-option-focus-0")
    XCTAssertEqual(app.buttons["request-option-focus-0"].value as? String, "Selected")
    tap("request-option-focus-1")
    XCTAssertEqual(app.buttons["request-option-focus-1"].value as? String, "Selected")
    tap("request-option-platform-0", direction: .down)
    tap("request-form-done")
    tap("request-form-open-gallery-question-request")
    XCTAssertEqual(app.buttons["request-option-focus-0"].value as? String, "Selected")
    XCTAssertEqual(app.buttons["request-option-focus-1"].value as? String, "Selected")
    let custom = element("request-custom-platform")
    reveal(custom, direction: .down)
    custom.tap()
    custom.typeText("A physical iPhone")
    tap("request-hide-keyboard")
    capture("events-structured-question")
    tap("request-form-submit")
    XCTAssertTrue(element("decision-status-gallery-question-request").waitForExistence(timeout: 5))
  }

  func testExternalConfirmationNeverOffersNativeApproval() {
    open("gallery-external")
    XCTAssertTrue(element("request-external-gallery-external-request").exists)
    XCTAssertFalse(app.buttons["approval-approve-gallery-external-request"].exists)
    XCTAssertFalse(app.buttons["approval-decline-gallery-external-request"].exists)
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
    capture("events-external-handoff")
  }

  func testPlanRejectionIncludesUserFeedback() {
    open("gallery-plan")
    let input = element("request-plan-feedback-gallery-plan-request")
    reveal(input, direction: .down)
    input.tap()
    input.typeText("Add a test for retained drafts.")
    tap("request-plan-reject-gallery-plan-request", direction: .down)
    XCTAssertTrue(element("decision-status-gallery-plan-request").waitForExistence(timeout: 5))
    XCTAssertEqual(element("decision-status-gallery-plan-request").label, "Rejected with feedback")
    capture("events-plan-feedback")
  }

  func testCommandPolicyChangeRequiresExplicitConfirmation() {
    open("gallery-policy")
    tap("request-command-policy-gallery-policy-request")
    tap("Cancel")
    XCTAssertFalse(element("decision-status-gallery-policy-request").exists)
    tap("request-command-policy-gallery-policy-request")
    capture("events-command-policy-confirmation")
    tap("Approve and apply this change")
    XCTAssertTrue(element("decision-status-gallery-policy-request").waitForExistence(timeout: 5))
    XCTAssertEqual(
      element("decision-status-gallery-policy-request").label,
      "Approved with command policy amendment")
  }

  func testSessionActivityAtLargestTextKeepsDoneAndDetailsReachable() {
    app.terminate()
    app.launchArguments += [
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    tap("open-demo")
    open("gallery-state")
    tap("session-options")
    tap("session-activity")
    tap("activity-toggle-state-usage", direction: .down)
    XCTAssertTrue(element("activity-detail-state-usage-context_tokens").exists)
    reveal(element("activity-detail-state-usage-context_tokens"), direction: .down)
    XCTAssertTrue(app.buttons["session-activity-done"].isHittable)
    capture("events-largest-text-usage")
    tap("activity-toggle-state-todos", direction: .down)
    XCTAssertTrue(element("activity-detail-state-todos-todo-0").exists)
    reveal(element("activity-detail-state-todos-todo-0"), direction: .down)
    capture("events-largest-text-tasks")
    tap("session-activity-done")
    XCTAssertTrue(app.buttons["composer-configuration"].exists)
  }

  private enum Direction { case up, down }

  private func open(_ id: String) {
    if id == "gallery-state" || id == "gallery-lifecycle" {
      let search = app.searchFields.firstMatch
      XCTAssertTrue(search.waitForExistence(timeout: 5))
      search.tap()
      search.typeText(id == "gallery-state" ? "Session state\n" : "Quiet lifecycle\n")
    }
    tap("session-row-\(id)", direction: .down)
    XCTAssertTrue(element("conversation-\(id)").waitForExistence(timeout: 5))
  }

  private func enter(_ text: String, field: String) {
    let input = element("request-field-\(field)")
    reveal(input, direction: .down)
    XCTAssertTrue(input.exists)
    XCTAssertTrue(
      visibleContentFrame().contains(CGPoint(x: input.frame.midX, y: input.frame.midY)),
      "Field must be above pinned controls")
    input.tap()
    input.typeText(text)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func tap(_ identifier: String, direction: Direction = .down) {
    if ["Cancel", "Approve and apply this change"].contains(identifier) {
      let action = app.buttons[identifier].firstMatch
      XCTAssertTrue(action.waitForExistence(timeout: 5))
      action.tap()
      return
    }
    let button = app.buttons[identifier].firstMatch
    let target = button.exists ? button : element(identifier)
    reveal(target, direction: direction)
    XCTAssertTrue(target.waitForExistence(timeout: 5), "Missing \(identifier)")
    XCTAssertTrue(target.isHittable, "Unreachable \(identifier)")
    target.tap()
  }

  private func reveal(_ target: XCUIElement, direction: Direction) {
    func isReachable() -> Bool {
      guard target.exists && target.isHittable else { return false }
      let id = target.identifier
      if [
        "request-form-done", "request-form-submit", "request-hide-keyboard", "session-options",
        "session-activity", "session-activity-done", "open-demo",
      ].contains(id) {
        return true
      }
      if app.alerts.firstMatch.exists { return true }
      return visibleContentFrame().contains(CGPoint(x: target.frame.midX, y: target.frame.midY))
    }
    if isReachable() { return }
    for _ in 0..<18 {
      if isReachable() { return }
      let visible = visibleContentFrame()
      var scrollDirection = direction
      if target.exists && !target.frame.isEmpty {
        if target.frame.midY < visible.minY {
          scrollDirection = .up
        } else if target.frame.midY > visible.maxY {
          scrollDirection = .down
        }
      }
      let origin = app.coordinate(withNormalizedOffset: .zero)
      let top = origin.withOffset(
        CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.2))
      let bottom = origin.withOffset(
        CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.8))
      (scrollDirection == .down ? bottom : top).press(
        forDuration: 0.1, thenDragTo: scrollDirection == .down ? top : bottom,
        withVelocity: .slow, thenHoldForDuration: 0.2)
    }
  }

  private func visibleContentFrame() -> CGRect {
    let navigationBottom =
      app.navigationBars.allElementsBoundByIndex.filter { $0.exists }.map { $0.frame.maxY }.max()
      ?? 80
    var top = max(80, navigationBottom + 8)
    var bottom = app.frame.maxY - 16
    if app.buttons["request-form-done"].exists {
      for id in ["request-form-submit", "request-form-validation", "request-form-error"] {
        let pinned = element(id)
        if pinned.exists { bottom = min(bottom, pinned.frame.minY - 12) }
      }
    } else if !app.buttons["session-activity-done"].exists {
      let composer = app.buttons["composer-configuration"]
      if composer.exists {
        bottom = min(bottom, composer.frame.minY - 24)
      } else {
        let search = app.searchFields.firstMatch
        if search.exists { top = max(top, search.frame.maxY + 8) }
        let tabs = app.tabBars.firstMatch
        if tabs.exists { bottom = min(bottom, tabs.frame.minY - 12) }
      }
    }
    if app.keyboards.firstMatch.exists {
      bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 16)
    }
    return CGRect(x: 8, y: top, width: app.frame.width - 16, height: max(44, bottom - top))
  }

  private func capture(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
