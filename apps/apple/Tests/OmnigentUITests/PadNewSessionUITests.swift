import XCTest

/// Every control of the iPad New Session page answers a tap against the local server: the
/// approval chip, the agent menu (harnesses and agents, models), the host, the folder chip and
/// its browser, the project chip, and Start, which creates the session and opens it.
final class PadNewSessionUITests: XCTestCase {
  @MainActor
  func testEveryNewSessionControlAnswersTaps() throws {
    let support = LiveServerUITestSupport(self)
    if support.isPhone { throw XCTSkip("iPad layout only") }
    let app = support.launch()
    support.showSessionList(app)
    support.tap(support.element("sidebar-new-session", in: app), "New Session")
    XCTAssertTrue(support.element("new-session-page", in: app).waitForExistence(timeout: 15))

    try checkApprovalChip(support, app)
    try checkAgentMenu(support, app)
    checkHostChip(support, app)
    checkFolderChip(support, app)
    checkProjectChip(support, app)
    checkHarnessSetup(support, app)

    let input = app.textViews["composer-input"]
    support.tap(input, "the composer")
    support.type("UI test: start a session from the iPad page", into: input)
    support.tap(app.buttons["composer-send"], "Start")
    XCTAssertTrue(
      support.element(prefix: "transcript-", in: app).waitForExistence(timeout: 30),
      "Start did not open the new session")
    support.shot("new-session-started")
  }

  /// The approval chip opens its menu, and picking another mode renames the chip. iOS menu
  /// items carry no identifiers, so they are found by label.
  @MainActor
  private func checkApprovalChip(_ support: LiveServerUITestSupport, _ app: XCUIApplication)
    throws
  {
    let chip = support.element("composer-approval-mode", in: app)
    support.tap(chip, "the approval chip", timeout: 15)
    let readOnly = app.buttons["Read only"]
    XCTAssertTrue(readOnly.waitForExistence(timeout: 5), "the approval menu did not open")
    support.shot("new-session-approval")
    let before = chip.label
    let choice = before.hasSuffix("Read only") ? app.buttons["Auto-edit"] : readOnly
    choice.tap()
    XCTAssertTrue(support.waitUntil { chip.label != before }, "picking a mode left \(before)")
  }

  /// The agent menu lists the harnesses and agents, and picking one closes it.
  @MainActor
  private func checkAgentMenu(_ support: LiveServerUITestSupport, _ app: XCUIApplication) throws {
    let menu = support.element("composer-configuration", in: app)
    support.tap(menu, "the agent picker")
    let harness = app.buttons["codex-native-ui"]
    XCTAssertTrue(harness.waitForExistence(timeout: 5), "the agent picker did not open")
    support.shot("new-session-agents")
    harness.tap()
    XCTAssertTrue(harness.waitForNonExistence(timeout: 5), "picking a harness left the menu")
    support.tap(menu, "the agent picker, again")
    XCTAssertTrue(harness.waitForExistence(timeout: 5), "the agent picker did not reopen")
    support.dismissMenu(app)
    XCTAssertTrue(harness.waitForNonExistence(timeout: 5), "the agent picker did not close")
  }

  @MainActor
  private func checkHostChip(_ support: LiveServerUITestSupport, _ app: XCUIApplication) {
    let host = support.element("composer-host", in: app)
    guard host.waitForExistence(timeout: 5), host.isEnabled else { return }
    host.tap()
    let online = app.buttons.matching(NSPredicate(format: "label CONTAINS 'NativeLab'")).firstMatch
    XCTAssertTrue(online.waitForExistence(timeout: 5), "the host menu did not open")
    online.tap()
  }

  /// The folder chip opens its menu; Browse Folders opens the browser and Choose sets the folder.
  @MainActor
  private func checkFolderChip(_ support: LiveServerUITestSupport, _ app: XCUIApplication) {
    let folder = support.element("new-session-folder", in: app)
    // A menu item: no identifier on iOS. A tap while the host menu closes can miss the chip.
    let browse = app.buttons["Browse Folders\u{2026}"]
    for _ in 0..<3 where !browse.exists {
      support.tap(folder, "the folder chip")
      _ = browse.waitForExistence(timeout: 5)
    }
    support.tap(browse, "Browse Folders")
    let choose = app.buttons["folder-browser-choose"]
    XCTAssertTrue(choose.waitForExistence(timeout: 10), "the folder browser did not open")
    XCTAssertTrue(support.waitUntil { choose.isEnabled }, "the folder browser loaded no folder")
    support.shot("new-session-folder-browser")
    choose.tap()
    XCTAssertTrue(choose.waitForNonExistence(timeout: 5), "Choose did not close the browser")
    XCTAssertFalse(folder.label.hasSuffix("none"), "Choose set no folder: \(folder.label)")
  }

  /// The project chip opens its menu, and picking a project names it on the chip.
  @MainActor
  private func checkProjectChip(_ support: LiveServerUITestSupport, _ app: XCUIApplication) {
    let project = support.element("new-session-project", in: app)
    guard project.waitForExistence(timeout: 5) else { return }
    project.tap()
    let noProject = app.buttons["No Project"]
    XCTAssertTrue(noProject.waitForExistence(timeout: 5), "the project menu did not open")
    let named = app.buttons.matching(
      NSPredicate(format: "label != 'No Project' AND identifier == ''")
    ).allElementsBoundByIndex.first { $0.frame.minY > noProject.frame.minY }
    guard let named else {
      noProject.tap()
      return
    }
    let name = named.label
    named.tap()
    XCTAssertTrue(
      support.waitUntil { project.label.contains(name) }, "picking \(name) left \(project.label)")
  }

  /// A harness that needs setup offers Set Up, which opens its sheet.
  @MainActor
  private func checkHarnessSetup(_ support: LiveServerUITestSupport, _ app: XCUIApplication) {
    let setUp = app.buttons["new-session-harness-setup"]
    guard setUp.exists else { return }
    setUp.tap()
    let sheet = support.element("harness-setup-sheet", in: app)
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Set Up did not open its sheet")
    support.shot("new-session-harness-setup")
    app.swipeDown(velocity: .fast)
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "the setup sheet did not close")
  }
}
