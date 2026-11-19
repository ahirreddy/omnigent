import XCTest

/// The Automations and Inbox pages: create an automation, and act on what the inbox asks.
final class MacPagesFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Creating an automation by hand lists it; deleting it from its menu cleans up.
  @MainActor
  func testCreatingAnAutomationListsIt() throws {
    let live = MacLiveUITestSupport(self)
    let workspace = try live.fixtureWorkspace()
    let app = live.launch()
    defer { app.terminate() }
    let name = "Flow \(UUID().uuidString.prefix(6))"

    live.click(live.element("sidebar-automations", in: app), "Automations", timeout: 30)
    // By its label: the intro sheet's identifier replaces its buttons' own.
    let intro = app.sheets.buttons["Maybe later"].firstMatch
    if intro.appears(within: 5) { intro.click() }
    XCTAssertTrue(intro.disappears(within: 10), "the intro stayed")
    live.click(live.element("automations-new", in: app), "New", timeout: 20)

    let nameField = live.element("automation-name", in: app)
    live.click(nameField, "the name field", timeout: 15)
    nameField.typeText(name)
    let prompt = live.element("automation-prompt", in: app)
    live.click(prompt, "the prompt field")
    prompt.typeText("Say hello from the flow.")
    // Every ten minutes, as the web's Interval schedule, from the frequency menu.
    live.click(live.element("automation-schedule-preset", in: app), "the frequency menu")
    live.clickMenuItem("Interval", in: app)
    pickHostAndSave(live, app, workspace: workspace)

    let listed = live.text(containing: name, in: app)
    XCTAssertTrue(listed.appears(within: 20), "the new automation is not listed")
    XCTAssertTrue(
      live.text(containing: "Every 10 minutes", in: app).appears(within: 10),
      "the minute rule shows raw\n\(app.debugDescription)")
    live.contextMenu(listed, choose: "Delete", in: app)
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(listed.disappears(within: 15), "the automation stayed")
  }

  /// A trigger from a template card lists as running when items match, and its page shows
  /// only its instructions, not the saved header or the manager prompt. Edit reopens its form.
  @MainActor
  func testATriggerShowsItsInstructions() throws {
    let live = MacLiveUITestSupport(self)
    let workspace = try live.fixtureWorkspace()
    let app = live.launch()
    defer { app.terminate() }
    let instructions = "Triage \(UUID().uuidString.prefix(6)) and report back."

    live.click(live.element("sidebar-automations", in: app), "Automations", timeout: 30)
    let intro = app.sheets.buttons["Maybe later"].firstMatch
    if intro.appears(within: 5) { intro.click() }
    XCTAssertTrue(intro.disappears(within: 10), "the intro stayed")
    live.click(live.element("automations-trigger-jira", in: app), "the Jira template", timeout: 20)

    let scope = live.element("automation-trigger-scope", in: app)
    live.click(scope, "the project field", timeout: 15)
    scope.typeText("ES")
    // As the web's, the instructions have a tab of their own.
    live.click(
      app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", "Instructions"))
        .firstMatch, "the Instructions tab")
    let field = live.element("automation-trigger-instructions", in: app)
    live.click(field, "the instructions field")
    field.typeText(instructions)
    XCTAssertFalse(
      live.element("automation-schedule-preset", in: app).exists,
      "a trigger polls, so its schedule stays out of the form")
    pickHostAndSave(live, app, workspace: workspace)

    let rule = live.text(containing: "Runs when new items match", in: app)
    XCTAssertTrue(
      rule.appears(within: 20), "the trigger row shows a schedule\n\(app.debugDescription)")
    live.click(rule, "the trigger's row")
    let shown = live.element("automation-detail-prompt", in: app)
    XCTAssertTrue(shown.appears(within: 15), "no prompt on the page")
    XCTAssertTrue(
      live.text(containing: instructions, in: app).appears(within: 10),
      "the instructions are missing")
    XCTAssertFalse(
      live.text(containing: "omnigent-trigger", in: app).exists, "the saved header shows")
    XCTAssertFalse(
      live.text(containing: "This automation watches Jira", in: app).exists,
      "the manager prompt shows")
    XCTAssertFalse(
      live.element("automation-detail-run-now", in: app).exists, "a trigger has Run now")

    live.click(live.element("automation-detail-edit", in: app), "Edit")
    let reopened = live.element("automation-trigger-scope", in: app)
    XCTAssertTrue(reopened.appears(within: 15), "Edit didn't reopen the trigger form")
    XCTAssertEqual(reopened.value as? String, "ES")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(reopened.disappears(within: 10), "the editor stayed")

    live.click(live.element("automation-detail-delete", in: app), "Delete")
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(rule.disappears(within: 15), "the trigger stayed")
  }

  /// A new automation's Trigger type swaps the schedule and instructions for a trigger's form,
  /// and back, keeping what was typed, as the web's.
  @MainActor
  func testTheTriggerTypeSwitchesTheForm() throws {
    let live = MacLiveUITestSupport(self)
    let app = live.launch()
    defer { app.terminate() }
    live.click(live.element("sidebar-automations", in: app), "Automations", timeout: 30)
    let intro = app.sheets.buttons["Maybe later"].firstMatch
    if intro.appears(within: 5) { intro.click() }
    XCTAssertTrue(intro.disappears(within: 10), "the intro stayed")
    live.click(live.element("automations-new", in: app), "New", timeout: 20)

    let prompt = live.element("automation-prompt", in: app)
    live.click(prompt, "the prompt field", timeout: 15)
    prompt.typeText("Look into it.")
    live.click(live.element("automation-trigger-type", in: app), "the trigger type")
    live.clickMenuItem("Jira", in: app)
    let scope = live.element("automation-trigger-scope", in: app)
    XCTAssertTrue(scope.appears(within: 10), "no trigger form\n\(app.debugDescription)")
    XCTAssertFalse(
      live.element("automation-schedule-preset", in: app).exists, "a trigger has no schedule")
    live.click(live.element("automation-trigger-type", in: app), "the trigger type")
    live.clickMenuItem("Schedule", in: app)
    XCTAssertTrue(prompt.appears(within: 10), "the schedule's form didn't come back")
    XCTAssertEqual(prompt.value as? String, "Look into it.", "the instructions were lost")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(prompt.disappears(within: 10), "the editor stayed")
  }

  /// Picks the first host, pins the fixture folder when offered, and saves.
  @MainActor
  private func pickHostAndSave(
    _ live: MacLiveUITestSupport, _ app: XCUIApplication, workspace: URL
  ) {
    live.click(live.element("automation-host", in: app), "the host picker")
    guard let host = live.hittable(app.menuItems) else {
      XCTFail("no hosts to pick\n\(app.debugDescription)")
      return
    }
    host.click()
    // The folder is under Advanced settings, folded until opened, as the web's.
    let folder = live.element("automation-workspace", in: app)
    if !folder.exists {
      live.click(live.element("automation-advanced", in: app), "Advanced settings")
    }
    if folder.appears(within: 5) {
      // The form is taller than a small screen: bring its last fields above the buttons.
      app.sheets.firstMatch.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -600)
      live.click(folder, "the folder field")
      app.typeText(workspace.path)
    }
    let save = live.element("automation-save", in: app)
    XCTAssertTrue(live.waitUntil(timeout: 15) { save.isEnabled }, "the form cannot be saved")
    save.click()
  }

  /// The pages are read again with each connection: after two Reconnects back to back, as a
  /// wake and an unlock send, Automations is in the sidebar and no read failure shows.
  @MainActor
  func testAutomationsStayAfterReconnecting() {
    let live = MacLiveUITestSupport(self)
    let app = live.launch()
    defer { app.terminate() }
    let automations = live.element("sidebar-automations", in: app)
    let failure = live.element("sidebar-pages-failure", in: app)
    XCTAssertTrue(automations.appears(within: 30), "no Automations row\n\(app.debugDescription)")

    app.typeKey("r", modifierFlags: [.command, .option, .shift])
    app.typeKey("r", modifierFlags: [.command, .option, .shift])
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { automations.exists && !failure.exists },
      "Automations did not come back\n\(app.debugDescription)")
    // Still there once the reconnects have settled.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    XCTAssertTrue(automations.exists, "Automations went after the reconnect")
    XCTAssertFalse(failure.exists, "the pages could not be read after the reconnect")
  }

  /// Approving a request from the Inbox clears it from the Inbox and from the session's row. A
  /// request to edit files is too large to approve on its row: Review shows the whole card.
  @MainActor
  func testInboxApproveResolvesARequest() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    openInbox(live, app)

    let review = live.elements(prefix: "inbox-decision-review-", in: app).firstMatch
    expandItem(live, app, showing: review)
    review.click()
    let approve = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier CONTAINS %@", "approval-approve-")
    ).firstMatch
    live.click(approve, "Approve", timeout: 15)
    XCTAssertTrue(approve.disappears(within: 15), "the request stayed")
    live.assertRow("demo-design", in: app, contains: "Needs you", false)
  }

  /// Answering a question in the Inbox clears it from the session's row.
  @MainActor
  func testInboxAnswerResolvesAQuestion() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    openInbox(live, app)

    let option = live.elements(prefix: "inbox-decision-option-", in: app).firstMatch
    expandItem(live, app, showing: option)
    option.click()
    live.assertRow("demo-question", in: app, contains: "Needs you", false)
  }

  /// Open session in an inbox item goes to that session.
  @MainActor
  func testInboxOpensTheSession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    openInbox(live, app)

    let open = live.elements(prefix: "inbox-open-", in: app).firstMatch
    expandItem(live, app, showing: open)
    open.click()
    XCTAssertTrue(
      live.anyTranscript(in: app).appears(within: 15), "the session did not open")
    XCTAssertFalse(live.element("inbox", in: app).exists, "the Inbox stayed")
  }

  @MainActor
  private func openInbox(_ live: MacLiveUITestSupport, _ app: XCUIApplication) {
    live.waitForDemoSessions(in: app)
    live.click(live.element("sidebar-inbox", in: app), "Inbox")
    XCTAssertTrue(live.element("inbox", in: app).appears(within: 15), "no Inbox")
  }

  /// Expands inbox items in turn until `target` shows.
  @MainActor
  private func expandItem(
    _ live: MacLiveUITestSupport, _ app: XCUIApplication, showing target: XCUIElement
  ) {
    let toggles = live.elements(prefix: "inbox-toggle-", in: app)
    for index in 0..<toggles.count where !target.exists {
      // On its first line: the middle of a long request is its text, not the toggle.
      toggles.element(boundBy: index).coordinate(withNormalizedOffset: .zero)
        .withOffset(CGVector(dx: 160, dy: 12)).click()
      _ = target.appears(within: 3)
    }
    XCTAssertTrue(target.appears(within: 10), "\(target) never showed")
  }
}
