import XCTest

/// The sidebar's search on the offline demo server: a collapsed section opens while searching,
/// so a match inside it shows, and closes again when the search is cleared.
final class SidebarSearchUITests: XCTestCase {
  @MainActor
  func testSearchExpandsACollapsedSection() {
    let app = XCUIApplication()
    app.launchArguments = [
      "-OmnigentDemo", "YES", "-desktop.defaultServerURL", "http://127.0.0.1:6767",
      "-ApplePersistenceIgnoreState", "YES", "-omnigent:sidebar-collapsed-sections", "Pinned",
    ]
    app.launch()
    defer { app.terminate() }
    let window = app.windows.firstMatch
    let pinned = window.descendants(matching: .any)["session-row-demo-design"]
    let other = window.descendants(matching: .any)["session-row-demo-notes"]
    XCTAssertTrue(other.waitForExistence(timeout: 30), "the demo sessions did not load")
    XCTAssertFalse(pinned.exists, "the collapsed Pinned section shows its row")

    let search = window.searchFields.firstMatch
    XCTAssertTrue(search.exists, "no sidebar search field")
    search.click()
    search.typeText("mobile")
    XCTAssertTrue(pinned.waitForExistence(timeout: 10), "searching left Pinned collapsed")

    search.typeKey("a", modifierFlags: .command)
    search.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(pinned.waitForNonExistence(timeout: 10), "clearing the search left Pinned open")
  }
}
