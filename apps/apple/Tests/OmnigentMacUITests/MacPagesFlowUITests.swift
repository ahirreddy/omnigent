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
    let intro = live.element("automations-intro-dismiss", in: app)
    if intro.waitForExistence(timeout: 5) { intro.click() }
    live.click(live.element("automations-new", in: app), "New automation", timeout: 20)
    live.clickMenuItem("Create manually", in: app)

    let nameField = live.element("automation-name", in: app)
    live.click(nameField, "the name field", timeout: 15)
    nameField.typeText(name)
    let prompt = live.element("automation-prompt", in: app)
    live.click(prompt, "the prompt field")
    prompt.typeText("Say hello from the flow.")
    live.click(live.element("automation-host", in: app), "the host picker")
    guard let host = live.hittable(app.menuItems) else {
      XCTFail("no hosts to pick\n\(app.debugDescription)")
      return
    }
    host.click()
    let folder = live.element("automation-workspace", in: app)
    if folder.waitForExistence(timeout: 5) {
      folder.click()
      folder.typeText(workspace.path)
    }
    let save = live.element("automation-save", in: app)
    XCTAssertTrue(live.waitUntil(timeout: 15) { save.isEnabled }, "the form cannot be saved")
    save.click()

    let listed = live.text(containing: name, in: app)
    XCTAssertTrue(listed.waitForExistence(timeout: 20), "the new automation is not listed")
    live.contextMenu(listed, choose: "Delete", in: app)
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(listed.waitForNonExistence(timeout: 15), "the automation stayed")
  }

  /// Approving a request in the Inbox clears it from the Inbox and from the session's row.
  @MainActor
  func testInboxApproveResolvesARequest() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    openInbox(live, app)

    let approve = live.elements(prefix: "inbox-approval-approve-", in: app).firstMatch
    expandItem(live, app, showing: approve)
    approve.click()
    XCTAssertTrue(approve.waitForNonExistence(timeout: 15), "the request stayed")
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
      live.anyTranscript(in: app).waitForExistence(timeout: 15), "the session did not open")
    XCTAssertFalse(live.element("inbox", in: app).exists, "the Inbox stayed")
  }

  @MainActor
  private func openInbox(_ live: MacLiveUITestSupport, _ app: XCUIApplication) {
    live.waitForDemoSessions(in: app)
    live.click(live.element("sidebar-inbox", in: app), "Inbox")
    XCTAssertTrue(live.element("inbox", in: app).waitForExistence(timeout: 15), "no Inbox")
  }

  /// Expands inbox items in turn until `target` shows.
  @MainActor
  private func expandItem(
    _ live: MacLiveUITestSupport, _ app: XCUIApplication, showing target: XCUIElement
  ) {
    let toggles = live.elements(prefix: "inbox-toggle-", in: app)
    for index in 0..<toggles.count where !target.exists {
      toggles.element(boundBy: index).click()
      _ = target.waitForExistence(timeout: 3)
    }
    XCTAssertTrue(target.waitForExistence(timeout: 10), "\(target) never showed")
  }
}
