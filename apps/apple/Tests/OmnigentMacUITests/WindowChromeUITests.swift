import AppKit
import XCTest

/// The real window's titlebar, which only the window server can check: the tab strip shares the
/// titlebar row with the toolbar, a drag on the strip's empty space moves the window, and a tab
/// drag reorders tabs without moving it.
///
/// Runs on the core's offline demo server (`-OmnigentDemo`), so it needs no server. Tabs are
/// saved in a scratch directory, never the user's.
final class WindowChromeUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testTitlebarTabsDragTheWindowAndReorder() {
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-chrome-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    let app = XCUIApplication()
    app.launchArguments = [
      "-OmnigentDemo", "-ApplePersistenceIgnoreState", "YES", "-OmnigentTabsDirectory", tabs.path,
    ]
    app.launch()
    defer { app.terminate() }
    let window = app.windows.firstMatch

    // A demo session's chat tab, from the sidebar.
    let row = window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'session-row-'")
    ).firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the demo listed no sessions")
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")

    // The tab strip shares the titlebar row with the trailing toolbar items.
    let strip = window.descendants(matching: .any)["tab-strip"]
    let inspector = window.descendants(matching: .any)["toggle-inspector"]
    XCTAssertTrue(strip.waitForExistence(timeout: 10) && inspector.exists)
    XCTAssertLessThan(
      abs(strip.frame.midY - inspector.frame.midY), 8,
      "strip \(strip.frame) and toolbar \(inspector.frame) are on different rows")
    XCTAssertLessThan(strip.frame.minY - window.frame.minY, 40, "the strip is below the titlebar")

    // With one tab the strip has empty space.
    checkEmptySpaceDrags(window: window, strip: strip)

    // A second tab (Option-Command-B opens a browser tab) to reorder against.
    app.typeKey("b", modifierFlags: [.command, .option])
    XCTAssertTrue(tab("browser", in: window).waitForExistence(timeout: 20), "no browser tab")
    checkTabDragReorders(window: window, chat: tab("chat", in: window))
  }

  /// A drag on the strip's empty space, between the last tab and New Tab, moves the window.
  @MainActor
  private func checkEmptySpaceDrags(window: XCUIElement, strip: XCUIElement) {
    let lastTab = tab("chat", in: window)
    let newTab = window.descendants(matching: .any)["tab-new"]
    XCTAssertTrue(lastTab.exists && newTab.exists)
    let gap = newTab.frame.minX - lastTab.frame.maxX
    XCTAssertGreaterThan(gap, 40, "no empty strip space: \(lastTab.frame), \(newTab.frame)")
    let drag = { (offset: CGVector) in
      let empty = strip.coordinate(withNormalizedOffset: .zero).withOffset(
        CGVector(
          dx: (lastTab.frame.maxX + newTab.frame.minX) / 2 - strip.frame.minX,
          dy: strip.frame.height / 2))
      empty.press(forDuration: 0.3, thenDragTo: empty.withOffset(offset))
    }
    let home = window.frame.origin
    let requested = CGVector(dx: -60, dy: 40)
    drag(requested)
    XCTAssertTrue(waitUntil { window.frame.origin != home }, "the strip's empty space did not drag")
    let moved = CGVector(dx: window.frame.minX - home.x, dy: window.frame.minY - home.y)
    // Put the window back, or its saved frame walks under the Dock run after run. The first
    // points of a drag only start it, so the way back is as long as the requested drag.
    let length = hypot(moved.dx, moved.dy)
    guard length > 0 else { return }
    let scale = -hypot(requested.dx, requested.dy) / length
    drag(CGVector(dx: moved.dx * scale, dy: moved.dy * scale))
  }

  /// A tab drag moves the tab, not the window.
  @MainActor
  private func checkTabDragReorders(window: XCUIElement, chat: XCUIElement) {
    let before = window.frame
    let kinds = tabKinds(window)
    let start = chat.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    start.press(
      forDuration: 0.3, thenDragTo: start.withOffset(CGVector(dx: chat.frame.width * 1.2, dy: 0)))
    XCTAssertTrue(
      waitUntil { self.tabKinds(window) != kinds }, "dragging the chat tab did not reorder it")
    XCTAssertEqual(window.frame.origin, before.origin, "dragging a tab moved the window")
  }

  /// Polls `condition` every 0.2 s for up to `timeout` seconds.
  @MainActor
  private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      Thread.sleep(forTimeInterval: 0.2)
    }
    return condition()
  }

  @MainActor
  private func tab(_ kind: String, in window: XCUIElement) -> XCUIElement {
    window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "tab-\(kind)-")
    ).firstMatch
  }

  /// The strip's tab kinds, left to right.
  @MainActor
  private func tabKinds(_ window: XCUIElement) -> [String] {
    window.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH 'tab-' AND NOT identifier BEGINSWITH 'tab-close-'")
    ).allElementsBoundByIndex
      .filter { element in
        let parts = element.identifier.split(separator: "-")
        return parts.count > 2
          && ["chat", "terminal", "agentTerminal", "browser", "newTab"].contains(String(parts[1]))
      }
      .sorted { $0.frame.minX < $1.frame.minX }
      .map { String($0.identifier.split(separator: "-")[1]) }
  }
}
