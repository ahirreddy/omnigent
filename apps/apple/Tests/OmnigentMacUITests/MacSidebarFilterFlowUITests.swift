import XCTest

/// Finding sessions in the sidebar on the offline demo server: search, the Running and Needs you
/// filters with their empty states and Show All Sessions, and the archived scope's empty state.
final class MacSidebarFilterFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Typing narrows the list to the matching session, and clearing restores the others.
  @MainActor
  func testSearchNarrowsTheListAndClearingRestoresIt() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.waitForDemoSessions(in: app)
    let notes = live.row("demo-notes", in: app)

    let search = app.windows.firstMatch.searchFields.firstMatch
    live.click(search, "the sidebar's search field")
    search.typeText("first release")
    XCTAssertTrue(notes.waitForNonExistence(timeout: 10), "search left a session that differs")
    XCTAssertTrue(live.row("demo-question", in: app).exists, "search hid the match")

    search.typeKey("a", modifierFlags: .command)
    search.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(notes.waitForExistence(timeout: 10), "clearing did not restore the list")
  }

  /// A search with no match says so.
  @MainActor
  func testSearchWithNoMatchSaysSo() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.waitForDemoSessions(in: app)

    let search = app.windows.firstMatch.searchFields.firstMatch
    live.click(search, "the sidebar's search field")
    search.typeText("zz-no-such-session")
    XCTAssertTrue(
      live.text(containing: "No Results", in: app).waitForExistence(timeout: 10),
      "no empty state for a search without matches")
    XCTAssertFalse(live.row("demo-question", in: app).exists, "a session still shows")
  }

  /// With nothing running, the Running filter says so, and Show All Sessions turns it off.
  @MainActor
  func testRunningFilterEmptyStateShowsAllSessions() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.waitForDemoSessions(in: app)

    live.click(live.element("quick-filter-running", in: app), "the Running filter")
    XCTAssertTrue(
      live.text(containing: "Nothing is running", in: app).waitForExistence(timeout: 10),
      "no empty state for Running")
    XCTAssertFalse(live.row("demo-question", in: app).exists, "an idle session still shows")

    live.click(live.element("sidebar-clear-filter", in: app), "Show All Sessions")
    live.waitForDemoSessions(in: app)
    XCTAssertTrue(live.row("demo-notes", in: app).exists, "Show All Sessions left the filter on")
  }

  /// The Running filter lists a session that is replying and no other.
  @MainActor
  func testRunningFilterListsARunningSession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startDemoSession("Summarize this in detail", in: app)
    XCTAssertTrue(
      live.element("composer-stop", in: app).waitForExistence(timeout: 15), "no reply started")

    live.click(live.element("quick-filter-running", in: app), "the Running filter")
    XCTAssertTrue(
      live.row("demo-notes", in: app).waitForNonExistence(timeout: 10), "an idle session stayed")
    XCTAssertTrue(
      live.elements(prefix: "session-row-demo-session-", in: app).firstMatch.exists,
      "the running session is not listed")
  }

  /// The Needs you filter lists the sessions waiting on a request and hides the rest.
  @MainActor
  func testNeedsYouFilterListsPendingRequests() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.waitForDemoSessions(in: app)

    live.click(live.element("quick-filter-needsResponse", in: app), "the Needs you filter")
    XCTAssertTrue(
      live.row("demo-notes", in: app).waitForNonExistence(timeout: 10), "an idle session stayed")
    XCTAssertTrue(live.row("demo-design", in: app).exists, "the approval is not listed")
    XCTAssertTrue(live.row("demo-question", in: app).exists, "the question is not listed")
  }

  /// Answering every request empties the Needs you filter, and Show All Sessions turns it off.
  @MainActor
  func testNeedsYouFilterEmptiesOnceAnswered() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-design", in: app)
    live.click(live.elements(prefix: "approval-approve-", in: app).firstMatch, "Approve")
    live.assertRow("demo-design", in: app, contains: "Needs you", false)
    live.openDemo("demo-question", in: app)
    live.click(live.elements(prefix: "decision-option-", in: app).firstMatch, "the first option")
    live.assertRow("demo-question", in: app, contains: "Needs you", false)

    live.click(live.element("quick-filter-needsResponse", in: app), "the Needs you filter")
    XCTAssertTrue(
      live.text(containing: "Nothing needs you", in: app).waitForExistence(timeout: 10),
      "no empty state for Needs you")
    live.click(live.element("sidebar-clear-filter", in: app), "Show All Sessions")
    live.waitForDemoSessions(in: app)
  }

  /// The archived scope with nothing archived says so, and All sessions comes back.
  @MainActor
  func testArchivedScopeEmptyState() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.waitForDemoSessions(in: app)

    live.showDisplayScope("Archived sessions", in: app)
    XCTAssertTrue(
      live.text(containing: "No archived sessions", in: app).waitForExistence(timeout: 10),
      "no empty state for the archived scope")
    XCTAssertFalse(live.row("demo-question", in: app).exists, "a live session still shows")

    live.showDisplayScope("All sessions", in: app)
    live.waitForDemoSessions(in: app)
  }
}
