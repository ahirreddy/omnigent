import XCTest

/// The palette's server search and Settings' agent-picker visibility against the local server
/// (seeded with `just apple-seed-large`, so a common word matches more than one page).
final class PaletteAndSettingsUITests: XCTestCase {
  @MainActor
  func testPaletteSearchShowsMore() throws {
    let support = LiveServerUITestSupport(self)
    let app = support.launch()
    support.showSessionList(app)
    support.tap(support.element("sidebar-search", in: app), "the palette button")
    let field = support.element("palette-search", in: app)
    XCTAssertTrue(field.waitForExistence(timeout: 5), "the palette did not open")
    app.typeText("Fix")
    let showMore = support.element("palette-show-more", in: app)
    let searching = support.element("palette-searching", in: app)
    XCTAssertTrue(
      support.waitUntil(timeout: 20) { showMore.exists && !searching.exists },
      "the search never offered Show more")
    let results = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'palette-result-'"))
    let before = results.count
    support.shot("palette-show-more")
    showMore.tap()
    XCTAssertTrue(
      support.waitUntil(timeout: 20) { !searching.exists && results.count > before },
      "Show more listed no more than \(before)")
    XCTAssertFalse(support.element("palette-search-retry", in: app).exists, "the search failed")
  }

  @MainActor
  func testSettingsHidesAnAgentFromThePickers() throws {
    let support = LiveServerUITestSupport(self)
    // Start with every agent shown; the argument is a plist string holding JSON.
    let app = support.launch(extra: [
      "-OmnigentOpenSettings", "appearance", "-omnigent:hidden-picker-agents", #""[]""#,
    ])
    let summary = support.element("settings.picker-visibility-summary", in: app)
    for _ in 0..<4 where !summary.waitForExistence(timeout: 5) { app.swipeUp() }
    XCTAssertTrue(
      support.waitUntil(timeout: 20) { summary.label.hasPrefix("Showing all") },
      "the summary is \(summary.label)")
    support.tap(support.element("settings.picker-visibility-edit", in: app), "Edit")
    let toggle = support.element("settings.picker-visibility-toggle-mock-model", in: app)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no mock-model in the checklist")
    // The row's switch sits at its trailing edge; a tap on the title does not flip it.
    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    XCTAssertTrue(
      support.waitUntil(timeout: 5) { (toggle.value as? String) == "0" },
      "mock-model is still shown: \(String(describing: toggle.value))")
    support.shot("settings-picker-visibility-edit")
    support.tap(app.buttons["Done"].firstMatch, "Done")
    XCTAssertTrue(
      support.waitUntil { summary.label.contains("Hidden:") },
      "hiding mock-model left \(summary.label)")
    support.tap(support.element("settings.picker-visibility-reset", in: app), "Show All")
    XCTAssertTrue(
      support.waitUntil { summary.label.hasPrefix("Showing all") },
      "Show All left \(summary.label)")
  }
}
