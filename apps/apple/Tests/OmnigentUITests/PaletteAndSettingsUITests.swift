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
    XCTAssertTrue(field.waitForExistence(timeout: 15), "the palette did not open")
    app.typeText("Fix")
    let showMore = support.element("palette-show-more", in: app)
    let searching = support.element("palette-searching", in: app)
    let list = support.element("command-palette", in: app).collectionViews.firstMatch
    // Show more ends the list, which a phone's keyboard hides; offscreen rows do not exist.
    XCTAssertTrue(
      support.waitUntil(timeout: 120) {
        if !showMore.exists, !searching.exists { scrollDown(list) }
        return showMore.exists && !searching.exists
      }, "the search never offered Show more")
    let before = resultIdentifiers(app)
    support.shot("palette-show-more")
    showMore.tap()
    XCTAssertTrue(
      support.waitUntil(timeout: 120) {
        if !searching.exists { scrollDown(list) }
        return !searching.exists && !resultIdentifiers(app).isSubset(of: before)
      }, "Show more listed nothing new")
    XCTAssertFalse(support.element("palette-search-retry", in: app).exists, "the search failed")
  }

  @MainActor
  func testSettingsHidesAnAgentFromThePickers() throws {
    let support = LiveServerUITestSupport(self)
    // Not set by a launch argument, which would shadow what the toggles store.
    let app = support.launch(extra: ["-OmnigentOpenSettings", "appearance"])
    let summary = support.element("settings.picker-visibility-summary", in: app)
    for _ in 0..<4 where !summary.waitForExistence(timeout: 5) { app.swipeUp() }
    let reset = support.element("settings.picker-visibility-reset", in: app)
    if reset.isEnabled { reset.tap() }
    XCTAssertTrue(
      support.waitUntil(timeout: 20) { summary.label.hasPrefix("Showing all") },
      "the summary is \(summary.label)")
    support.tap(support.element("settings.picker-visibility-edit", in: app), "Edit")
    let toggle = support.element("settings.picker-visibility-toggle-mock-model", in: app)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no mock-model in the checklist")
    // The row's own switch flips it; a tap on the title does not.
    let control = toggle.switches.firstMatch
    if control.exists {
      control.tap()
    } else {
      toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }
    support.shot("settings-picker-visibility-edit")
    support.tap(app.buttons["Done"].firstMatch, "Done")
    XCTAssertTrue(
      support.waitUntil { summary.label.contains("Hidden:") },
      "hiding mock-model left \(summary.label)")
    support.tap(reset, "Show All")
    XCTAssertTrue(
      support.waitUntil { summary.label.hasPrefix("Showing all") },
      "Show All left \(summary.label)")
  }

  /// The palette's results now on screen.
  @MainActor
  private func resultIdentifiers(_ app: XCUIApplication) -> Set<String> {
    let results = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'palette-result-'"))
    return Set(results.allElementsBoundByIndex.map(\.identifier))
  }

  /// Drags `list` up by most of its height (a swipe here leaves the palette's list in place).
  @MainActor
  private func scrollDown(_ list: XCUIElement) {
    let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
    start.press(
      forDuration: 0.05,
      thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
  }
}
