import XCTest

@MainActor
final class NativeLabUITests: XCTestCase {
  private var app: XCUIApplication!

  private let sampleReply =
    "Got it. This is a sample reply from the offline demo. Your message stayed in this conversation. You can try another message or create a new session."

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--ui-testing", "--reset-demo"]
    app.launch()
  }

  override func tearDownWithError() throws {
    XCUIDevice.shared.orientation = .portrait
    app.terminate()
    app = nil
  }

  func testNotificationSetupIsExplicitAndReportsUnavailablePush() {
    openSampleWorkspace()
    XCTAssertFalse(app.alerts.firstMatch.exists)
    selectTab("Settings", identifier: "settings-tab")
    let status = element("notification-status")
    for _ in 0..<8 {
      if status.exists && status.isHittable { break }
      app.swipeUp()
    }
    XCTAssertTrue(status.exists)
    XCTAssertTrue(status.label.contains("unavailable"))
    XCTAssertFalse(app.alerts.firstMatch.exists)
    let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    image.name = "notification-setup-status"
    image.lifetime = .keepAlways
    add(image)
  }

  func testApprovalUnblocksSendingAndStreamsAReply() {
    openSampleWorkspace()
    tapButton("session-row-demo-design")

    XCTAssertTrue(element("composer-unavailable-demo-design").waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
    tapButton("approval-approve-decision-design")

    XCTAssertTrue(element("decision-status-decision-design").waitForExistence(timeout: 5))
    waitUntilGone(app.buttons["approval-approve-decision-design"])
    enterText("Review the native navigation", into: "composer-input")
    tapButton("send-message")

    XCTAssertTrue(message("Review the native navigation").waitForExistence(timeout: 5))
    XCTAssertTrue(message(sampleReply).waitForExistence(timeout: 15))
    waitUntilGone(app.buttons["stop-response"])
    XCTAssertTrue(element("conversation-demo-design").exists)
  }

  func testInboxQuestionRemovesOnlyTheAnsweredSession() {
    openSampleWorkspace()
    selectTab("Inbox", identifier: "inbox-tab")
    XCTAssertTrue(app.buttons["session-row-demo-design"].waitForExistence(timeout: 5))
    tapButton("session-row-demo-question")

    XCTAssertTrue(element("composer-unavailable-demo-question").waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
    tapButton("question-option-decision-question-0")

    XCTAssertTrue(element("decision-status-decision-question").waitForExistence(timeout: 5))
    waitUntilGone(app.buttons["question-option-decision-question-0"])
    waitUntilGone(element("composer-unavailable-demo-question"))

    let back =
      app.buttons["BackButton"].exists
      ? app.buttons["BackButton"].firstMatch : app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(app.buttons["session-row-demo-design"].waitForExistence(timeout: 5))
    waitUntilGone(app.buttons["session-row-demo-question"])
    XCTAssertFalse(element("inbox-empty").exists)
  }

  func testReadOnlySessionExplainsWhySendingIsUnavailable() {
    openSampleWorkspace()
    tapButton("session-row-demo-notes")

    XCTAssertTrue(element("conversation-demo-notes").waitForExistence(timeout: 5))
    XCTAssertTrue(element("composer-unavailable-demo-notes").waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["send-message"].exists)
    XCTAssertFalse(app.buttons["send-message"].isEnabled)
    XCTAssertFalse(element("composer-input").isEnabled)
  }

  func testCreateSessionOpensItAndSendsTheInitialPrompt() {
    openSampleWorkspace()
    tapButton("new-session")
    XCTAssertTrue(app.buttons["create-session"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["create-session"].isEnabled)

    enterText("Mobile review", into: "new-session-title")
    enterText("Outline a small native session screen", into: "new-session-prompt")
    tapButton("create-session")

    XCTAssertTrue(app.navigationBars["Mobile review"].waitForExistence(timeout: 10))
    XCTAssertTrue(message("Outline a small native session screen").waitForExistence(timeout: 5))
    XCTAssertTrue(message(sampleReply).waitForExistence(timeout: 15))
    waitUntilGone(app.buttons["stop-response"])
  }

  func testExpandedComposerPreservesExactDraftAcrossNavigationAndRelaunch() {
    openSampleWorkspace()
    capture("01-sessions")
    tapButton("session-row-demo-design")
    tapButton("expand-composer")
    let draft = "Review the mobile layout.\nKeep the composer native and responsive."
    enterText(draft, into: "expanded-composer-input")
    XCTAssertFalse(app.buttons["expanded-send-message"].isEnabled)
    capture("02-expanded-composer")
    tapButton("expanded-composer-details")
    XCTAssertTrue(element("expanded-composer-unavailable").waitForExistence(timeout: 5))
    tapButton("composer-details-done")
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
    tapButton("composer-done")
    XCTAssertEqual(element("composer-input").value as? String, draft)
    goBack()
    tapButton("session-row-demo-question")
    XCTAssertNotEqual(element("composer-input").value as? String, draft)
    goBack()
    app.terminate()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    openSampleWorkspace()
    tapButton("session-row-demo-design")
    tapButton("expand-composer")
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
    tapButton("composer-done")
    tapButton("approval-approve-decision-design")
    tapButton("expand-composer")
    tapButton("expanded-send-message")
    waitUntilGone(element("expanded-composer-input"))
    XCTAssertTrue(message(draft).waitForExistence(timeout: 5))
    XCTAssertTrue(message(sampleReply).waitForExistence(timeout: 15))
    capture("03-conversation")
  }

  func testRenamePinArchiveRestoreAndSearch() {
    openSampleWorkspace()
    tapButton("session-row-demo-question")
    tapButton("session-options")
    tapButton("session-rename")
    let input = element("rename-input")
    XCTAssertTrue(input.waitForExistence(timeout: 5))
    input.tap()
    let oldName = input.value as? String ?? ""
    input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldName.count))
    input.typeText("Release checklist")
    tapButton("rename-save")
    XCTAssertTrue(app.navigationBars["Release checklist"].waitForExistence(timeout: 5))
    tapButton("session-options")
    tapButton("session-pin")
    tapButton("session-options")
    tapButton("session-archive")
    XCTAssertTrue(element("composer-unavailable-demo-question").exists)
    goBack()
    waitUntilGone(app.buttons["session-row-demo-question"])
    tapButton("session-filter")
    tapButton("filter-Archived")
    tapButton("session-row-demo-question")
    tapButton("session-options")
    tapButton("session-archive")
    goBack()
    waitUntilGone(app.buttons["session-row-demo-question"])
    app.terminate()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    openSampleWorkspace()
    XCTAssertTrue(app.buttons["session-row-demo-question"].label.contains("Release checklist"))
    let search = app.searchFields.firstMatch
    if !search.isHittable { app.swipeDown() }
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Planning")
    XCTAssertTrue(app.buttons["session-row-demo-question"].waitForExistence(timeout: 5))
    waitUntilGone(app.buttons["session-row-demo-design"])
    capture("04-session-search")
  }

  func testNewSessionDraftSurvivesSheetDismissal() {
    openSampleWorkspace()
    tapButton("new-session")
    enterText("A new mobile idea", into: "new-session-prompt")
    tapButton("Cancel")
    tapButton("new-session")
    XCTAssertEqual(element("new-session-prompt").value as? String, "A new mobile idea")
    tapButton("create-session")
    XCTAssertTrue(message("A new mobile idea").waitForExistence(timeout: 10))
  }

  func testExpandedComposerSupportsLargeTextAndLandscape() {
    app.terminate()
    app.launchArguments = [
      "--ui-testing", "--reset-demo",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    openSampleWorkspace()
    tapButton("session-row-demo-design")
    tapButton("expand-composer")
    enterText("A larger, more readable draft.", into: "expanded-composer-input")
    XCTAssertTrue(app.buttons["composer-done"].isHittable)
    XCTAssertTrue(app.buttons["expanded-send-message"].exists)
    XCTAssertGreaterThanOrEqual(
      element("expanded-composer-input").frame.intersection(app.frame).height, 44,
      "The expanded editor needs usable space at the largest text size.")
    assertEditorAboveKeyboard()
    capture("05-large-text-composer")
    XCUIDevice.shared.orientation = .landscapeLeft
    XCTAssertTrue(app.buttons["composer-done"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["composer-done"].isHittable)
    XCTAssertTrue(element("expanded-composer-input").isHittable)
    XCTAssertGreaterThanOrEqual(
      element("expanded-composer-input").frame.intersection(app.frame).height, 44,
      "The expanded editor needs usable space in landscape.")
    assertEditorAboveKeyboard()
    capture("06-landscape-composer")
    tapButton("composer-done")
    XCTAssertEqual(element("composer-input").value as? String, "A larger, more readable draft.")
  }

  func testConfigurationModelSearchApplyCancelAndDraftPersistence() {
    openIdleSampleSession()
    let draft = "Keep this message while I choose session settings."
    enterText(draft, into: "composer-input")
    tapButton("dismiss-keyboard")
    assertComposerBranding(modelLabel: "Sample Balanced", harness: "Codex", brand: "codex")
    capture("branding-codex-inline-composer")
    tapButton("composer-configuration")
    XCTAssertFalse(app.buttons["configuration-apply"].isEnabled)
    tapButton("configuration-model")
    let search = app.searchFields.firstMatch
    if !search.isHittable { app.collectionViews.firstMatch.swipeDown() }
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Fast")
    XCTAssertTrue(element("model-current-value").exists)
    XCTAssertEqual(element("model-current-value").label, "Sample Balanced")
    XCTAssertFalse(app.buttons["model-sample-balanced"].exists)
    tapButton("model-sample-fast")
    tapButton("configuration-effort")
    XCTAssertFalse(app.buttons["effort-high"].exists)
    tapButton("effort-low")
    tapButton("configuration-apply")
    waitUntilGone(app.buttons["configuration-done"])
    assertComposerBranding(modelLabel: "Sample Fast", harness: "Codex", brand: "codex")
    XCTAssertEqual(element("composer-input").value as? String, draft)

    tapButton("composer-configuration")
    XCTAssertTrue(app.buttons["configuration-effort"].label.contains("Low"))
    tapButton("configuration-model")
    tapButton("model-sample-balanced")
    tapButton("configuration-effort")
    tapButton("effort-high")
    tapButton("configuration-done")
    assertComposerBranding(modelLabel: "Sample Fast", harness: "Codex", brand: "codex")
    XCTAssertEqual(element("composer-input").value as? String, draft)
    goBack()
    XCTAssertTrue(app.buttons["session-row-demo-design"].label.contains("Codex · Sample Fast"))

    app.terminate()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    openSampleWorkspace()
    tapButton("session-row-demo-design")
    assertComposerBranding(modelLabel: "Sample Fast", harness: "Codex", brand: "codex")
    XCTAssertEqual(element("composer-input").value as? String, draft)
    capture("picker-model-applied-draft-preserved")
  }

  func testExpandedConfigurationSupportsEffortResetAndHarnessDefault() {
    openIdleSampleSession()
    tapButton("expand-composer")
    let draft = "An expanded editor draft.\nPreserve both lines."
    enterText(draft, into: "expanded-composer-input")
    tapButton("expanded-configuration")
    tapButton("configuration-effort")
    tapButton("effort-high")
    tapButton("configuration-model")
    tapButton("model-sample-fast")
    XCTAssertTrue(app.buttons["configuration-effort"].label.contains("Harness default"))
    tapButton("configuration-apply")
    waitUntilGone(app.buttons["configuration-done"])
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
    assertComposerBranding(
      modelLabel: "Sample Fast", harness: "Codex", brand: "codex", expanded: true)
    assertSendAvailable(expanded: true)
    capture("branding-codex-expanded-composer")
    tapButton("expanded-configuration")
    tapButton("configuration-model")
    tapButton("model-default")
    tapButton("configuration-apply")
    waitUntilGone(app.buttons["configuration-done"])
    assertComposerBranding(
      modelLabel: "Harness default", harness: "Codex", brand: "codex", expanded: true)
    assertSendAvailable(expanded: true)
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
    tapButton("composer-done")
    XCTAssertEqual(element("composer-input").value as? String, draft)
  }

  func testConfigurationBusyReadOnlyAndArchivedRemainInspectable() {
    openSampleWorkspace()
    tapButton("session-row-demo-design")
    tapButton("composer-configuration")
    XCTAssertTrue(element("configuration-unavailable").label.contains("pending request"))
    XCTAssertFalse(app.buttons["configuration-apply"].isEnabled)
    tapButton("configuration-model")
    XCTAssertFalse(app.buttons["model-sample-fast"].isEnabled)
    configurationBack()
    tapButton("configuration-harness")
    XCTAssertTrue(app.buttons["harness-demo-claude"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["harness-demo-claude"].isEnabled)
    configurationBack()
    tapButton("configuration-details")
    XCTAssertTrue(message("codex-native").waitForExistence(timeout: 5))
    XCTAssertTrue(message("sample-balanced").exists)
    tapButton("configuration-done")

    tapButton("approval-approve-decision-design")
    waitUntilGone(app.buttons["approval-approve-decision-design"])
    tapButton("session-options")
    tapButton("session-archive")
    tapButton("composer-configuration")
    XCTAssertTrue(element("configuration-unavailable").label.contains("Restore this session"))
    XCTAssertFalse(app.buttons["configuration-apply"].isEnabled)
    tapButton("configuration-done")
    goBack()
    tapButton("session-row-demo-notes")
    tapButton("composer-configuration")
    XCTAssertTrue(element("configuration-unavailable").label.contains("read-only access"))
    XCTAssertFalse(app.buttons["configuration-apply"].isEnabled)
    tapButton("configuration-effort")
    XCTAssertFalse(app.buttons["effort-low"].isEnabled)
    configurationBack()
    tapButton("configuration-details")
    XCTAssertTrue(message("codex-native").waitForExistence(timeout: 5))
    capture("picker-read-only-details")
  }

  func testConfirmedHarnessSwitchPreservesSessionTranscriptAndDraft() {
    openIdleSampleSession()
    assertComposerBranding(modelLabel: "Sample Balanced", harness: "Codex", brand: "codex")
    let draft = "Continue this same conversation after the harness switch."
    enterText(draft, into: "composer-input")
    tapButton("dismiss-keyboard")
    tapButton("composer-configuration")
    tapButton("configuration-harness")
    XCTAssertFalse(app.buttons["harness-demo-codex"].isEnabled)
    tapButton("harness-demo-claude")
    tapButton("configuration-apply")
    let alert = app.descendants(matching: .any)
      .matching(NSPredicate(format: "label == %@", "Switch to Claude Code?")).firstMatch
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    XCTAssertTrue(
      alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "reset")).firstMatch
        .exists)
    alert.buttons["Cancel"].tap()
    XCTAssertEqual(element("configuration-current").label, "Codex · Sample Balanced")
    tapButton("configuration-apply")
    XCTAssertTrue(alert.waitForExistence(timeout: 5))
    let diagnostic = XCTAttachment(string: app.debugDescription)
    diagnostic.name = "demo-harness-confirmation-hierarchy"
    diagnostic.lifetime = .deleteOnSuccess
    add(diagnostic)
    let identified = alert.descendants(matching: .any)
      .matching(identifier: "configuration-confirm-switch").firstMatch
    let confirm = identified.exists ? identified : alert.buttons["Switch harness"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(confirm.isEnabled && confirm.isHittable)
    confirm.tap()
    waitUntilGone(app.buttons["configuration-done"])
    assertComposerBranding(modelLabel: "Harness default", harness: "Claude Code", brand: "claude")
    assertSendAvailable()
    XCTAssertEqual(element("composer-input").value as? String, draft)
    XCTAssertTrue(element("conversation-demo-design").exists)
    XCTAssertTrue(element("message-text-design-proposal").exists)
    capture("branding-claude-inline-composer")
    tapButton("expand-composer")
    assertComposerBranding(
      modelLabel: "Harness default", harness: "Claude Code", brand: "claude", expanded: true)
    assertSendAvailable(expanded: true)
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
    capture("branding-claude-expanded-composer")
    tapButton("composer-done")
    tapButton("composer-configuration")
    tapButton("configuration-details")
    revealConfigurationText("demo-design")
    XCTAssertTrue(message("demo-design").exists)
    XCTAssertTrue(message("demo-claude").exists)
    capture("picker-confirmed-harness-details")
    tapButton("configuration-done")
    goBack()
    XCTAssertTrue(
      app.buttons["session-row-demo-design"].label.contains("Claude Code · Harness default"))
  }

  func testConfigurationLargestTextKeepsPrimaryControlsReachable() {
    app.terminate()
    app.launchArguments = [
      "--ui-testing", "--reset-demo",
      "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
    ]
    app.launch()
    openIdleSampleSession()
    tapButton("expand-composer")
    let draft = "A readable settings picker keeps my draft."
    enterText(draft, into: "expanded-composer-input")
    XCTAssertTrue(app.buttons["expanded-configuration"].isHittable)
    tapButton("expanded-configuration")
    XCTAssertTrue(app.buttons["configuration-done"].isHittable)
    XCTAssertGreaterThanOrEqual(
      app.buttons["configuration-apply"].frame.intersection(app.frame).height, 44)
    tapButton("configuration-model")
    tapButton("model-sample-fast")
    XCTAssertTrue(app.buttons["configuration-apply"].isHittable)
    capture("picker-largest-text-before-apply")
    tapButton("configuration-apply")
    waitUntilGone(app.buttons["configuration-done"])
    XCTAssertEqual(element("expanded-composer-input").value as? String, draft)
    XCTAssertTrue(app.buttons["composer-done"].isHittable)
    capture("picker-largest-text-expanded-draft")
    tapButton("composer-done")
    XCTAssertEqual(element("composer-input").value as? String, draft)
  }

  private func assertComposerBranding(
    modelLabel: String, harness: String, brand: String, expanded: Bool = false,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let prefix = expanded ? "expanded" : "composer"
    let configuration = app.buttons[expanded ? "expanded-configuration" : "composer-configuration"]
    XCTAssertEqual(configuration.label, "Harness and model", file: file, line: line)
    XCTAssertEqual(
      configuration.value as? String, "\(harness) · \(modelLabel)", file: file, line: line)
    let visibleModel = configuration.staticTexts["\(prefix)-model-label"]
    XCTAssertTrue(visibleModel.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertEqual(visibleModel.label, modelLabel, file: file, line: line)
    XCTAssertFalse(visibleModel.label.contains(harness), file: file, line: line)
    XCTAssertFalse(
      configuration.staticTexts.matching(
        NSPredicate(format: "label == %@", "\(harness) · \(modelLabel)")
      ).firstMatch.exists, "The visible model text must not repeat the harness name.",
      file: file, line: line)
    let logo = configuration.descendants(matching: .any)
      .matching(identifier: "\(prefix)-harness-logo").firstMatch
    XCTAssertTrue(logo.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertTrue(
      logo.label == harness || logo.value as? String == brand,
      "The displayed logo must identify this session's harness.", file: file, line: line)
    let send = app.buttons[expanded ? "expanded-send-message" : "send-message"]
    XCTAssertEqual(send.label, "Send message", file: file, line: line)
    XCTAssertEqual(send.value as? String, brand, file: file, line: line)
  }

  private func assertSendAvailable(
    expanded: Bool = false, file: StaticString = #filePath, line: UInt = #line
  ) {
    let sendingAvailable = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"),
      object: app.buttons[expanded ? "expanded-send-message" : "send-message"])
    XCTAssertEqual(
      XCTWaiter.wait(for: [sendingAvailable], timeout: 10), .completed, file: file, line: line)
  }

  private func openIdleSampleSession() {
    openSampleWorkspace()
    XCTAssertTrue(app.buttons["session-row-demo-design"].label.contains("Codex · Sample Balanced"))
    tapButton("session-row-demo-design")
    tapButton("approval-approve-decision-design")
    waitUntilGone(app.buttons["approval-approve-decision-design"])
    waitUntilGone(element("composer-unavailable-demo-design"))
  }

  private func configurationBack() {
    let navigation = app.navigationBars.matching(
      NSPredicate(format: "identifier IN %@", ["Model", "Harness", "Reasoning", "Session details"])
    )
    .firstMatch
    XCTAssertTrue(navigation.waitForExistence(timeout: 5))
    navigation.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["configuration-apply"].waitForExistence(timeout: 5))
  }

  private func revealConfigurationText(_ text: String) {
    let container = app.collectionViews.firstMatch
    for _ in 0..<8 {
      if message(text).exists && message(text).isHittable { return }
      container.swipeUp()
    }
  }

  private func assertEditorAboveKeyboard(file: StaticString = #filePath, line: UInt = #line) {
    let editor = element("expanded-composer-input").frame.intersection(app.frame)
    let keyboard = app.keyboards.firstMatch
    XCTAssertTrue(
      keyboard.exists, "Exercise the software keyboard, not only the editor frame.", file: file,
      line: line)
    let visibleHeight = min(editor.maxY, keyboard.frame.minY) - editor.minY
    XCTAssertGreaterThanOrEqual(
      visibleHeight, 44, "Keep editable space above the keyboard.", file: file, line: line)
    XCTAssertTrue(app.buttons["expanded-dismiss-keyboard"].isHittable, file: file, line: line)
  }

  private func goBack() {
    let back =
      app.buttons["BackButton"].exists
      ? app.buttons["BackButton"].firstMatch : app.navigationBars.buttons.element(boundBy: 0)
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
  }

  private func capture(_ name: String) {
    // Foldable devices can render the app on a non-primary panel.
    for (index, screen) in XCUIScreen.screens.enumerated() {
      let attachment = XCTAttachment(screenshot: screen.screenshot())
      attachment.name = "\(name)-display-\(index)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  private func openSampleWorkspace(file: StaticString = #filePath, line: UInt = #line) {
    tapButton("open-demo", file: file, line: line)
    revealScrollableButton("session-row-demo-design")
    XCTAssertTrue(
      app.buttons["session-row-demo-design"].waitForExistence(timeout: 10),
      "Expected the isolated sample sessions to load.", file: file, line: line
    )
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func selectTab(
    _ title: String, identifier: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let identifiedTab = app.buttons[identifier].firstMatch
    let tab = identifiedTab.exists ? identifiedTab : app.tabBars.buttons[title].firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 5), file: file, line: line)
    tab.tap()
  }

  private func message(_ text: String) -> XCUIElement {
    app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
  }

  private func tapButton(
    _ identifier: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    revealScrollableButton(identifier)
    let button = app.buttons[identifier].firstMatch
    XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true AND hittable == true"), object: button
    )
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file, line: line)
    button.tap()
  }

  private func revealScrollableButton(_ identifier: String) {
    if ["configuration-apply", "configuration-done"].contains(identifier) { return }
    let container: XCUIElement
    if identifier.hasPrefix("session-row-") {
      container = app.collectionViews.firstMatch
    } else if identifier.hasPrefix("approval-") {
      container =
        app.scrollViews.matching(
          NSPredicate(format: "identifier BEGINSWITH %@", "conversation-")
        ).firstMatch
    } else if ["configuration-", "model-", "effort-", "harness-"].contains(
      where: identifier.hasPrefix)
    {
      container = app.collectionViews.firstMatch
    } else {
      return
    }
    guard container.waitForExistence(timeout: 5) else { return }
    let button = app.buttons[identifier].firstMatch
    func isReachable() -> Bool {
      guard button.exists && button.isHittable else { return false }
      return visibleScrollFrame(container, identifier: identifier)
        .contains(CGPoint(x: button.frame.midX, y: button.frame.midY))
    }
    // Lazy lists and long drafts can put controls outside a compact phone's viewport.
    for _ in 0..<12 {
      if isReachable() { return }
      scrollVisibleContent(container, identifier: identifier, forward: true)
    }
    for _ in 0..<12 {
      if isReachable() { return }
      scrollVisibleContent(container, identifier: identifier, forward: false)
    }
  }

  private func visibleScrollFrame(_ container: XCUIElement, identifier: String) -> CGRect {
    var visible = container.frame.intersection(app.frame)
    let navigation = app.navigationBars.firstMatch
    let top = navigation.exists ? max(visible.minY, navigation.frame.maxY) + 8 : visible.minY
    var bottom = visible.maxY
    // SwiftUI reports the scroll view beneath its pinned safe-area content as full screen.
    let pinned = app.buttons[
      identifier.hasPrefix("approval-") ? "composer-configuration" : "configuration-apply"
    ]
    if pinned.exists { bottom = min(bottom, pinned.frame.minY - 16) }
    visible = CGRect(x: visible.minX, y: top, width: visible.width, height: max(44, bottom - top))
    return visible
  }

  private func scrollVisibleContent(
    _ container: XCUIElement, identifier: String, forward: Bool
  ) {
    let visible = visibleScrollFrame(container, identifier: identifier)
    let origin = app.coordinate(withNormalizedOffset: .zero)
    let upper = origin.withOffset(
      CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.25))
    let lower = origin.withOffset(
      CGVector(dx: visible.midX, dy: visible.minY + visible.height * 0.75))
    (forward ? lower : upper).press(forDuration: 0.1, thenDragTo: forward ? upper : lower)
  }

  private func enterText(
    _ text: String, into identifier: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    let input = element(identifier)
    XCTAssertTrue(input.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertTrue(input.isEnabled, file: file, line: line)
    input.tap()
    input.typeText(text)
  }

  private func waitUntilGone(
    _ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element
    )
    XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed, file: file, line: line)
  }
}
