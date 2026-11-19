import XCTest

/// The Tasks tab on the local server's tasks session, seeded by `Tools/seed-ui-test-fixtures.py`
/// with the agent's own task list and two of its task markers.
final class MacTasksFlowUITests: XCTestCase {
  /// `fixed_id("ui-test", "tasks")`, which the seeder gives the session.
  private static let tasksSession = "1a511467053f5af4aee51cef091e71b0"

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// The tab lists the agent's tasks with where they stand, and a task marker in the chat opens
  /// the tab from another one.
  @MainActor
  func testTasksTabListsTheAgentsTasksAndMarkersOpenIt() throws {
    let live = MacLiveUITestSupport(self)
    _ = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(Self.tasksSession, in: app)
    // Opening a session that has tasks shows its Tasks tab, as the web does.
    XCTAssertTrue(
      live.element("tasks-panel", in: app).appears(within: 20),
      "opening the session did not show its Tasks tab")
    live.showInspector(in: app)

    live.click(live.element("inspector-tab-tasks", in: app), "the Tasks tab", timeout: 20)
    XCTAssertTrue(live.element("tasks-panel", in: app).appears(within: 20), "no Tasks tab")
    for task in ["task-read", "task-fix", "task-test"] {
      XCTAssertTrue(
        live.element("tasks-row-\(task)", in: app).appears(within: 10), "\(task) is not listed")
    }
    XCTAssertTrue(
      live.text(containing: "1 of 3 finished", in: app).appears(within: 10), "no summary")
    live.shot(app, "tasks-tab-native-list")

    // Away on Files, a marker's task name brings the Tasks tab back.
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")
    XCTAssertTrue(live.element("tasks-panel", in: app).disappears(within: 10))
    let marker = live.elements(prefix: "task-marker-open-", in: app).firstMatch
    live.click(marker, "a task marker's link", timeout: 20)
    XCTAssertTrue(
      live.element("tasks-panel", in: app).appears(within: 10),
      "the marker did not open the Tasks tab")
    live.assertRunning(app, "after following a task marker")
  }
}
