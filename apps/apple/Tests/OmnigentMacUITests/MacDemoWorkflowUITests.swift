import AppKit
import XCTest

/// Everyday Mac workflows on the core's offline demo server, so they need no server: the command
/// palette, sending and stopping a reply, tabs (new, close, reopen, cycle, overview, split), the
/// sidebar and inspector, sheets, Settings, windows, zoom, and drafts across sessions. Each step
/// checks that the app is still running, so a crash fails at the step that caused it.
///
/// They take the real mouse and keyboard; run them in a VM (`vm-test.sh MacDemoWorkflowUITests`).
final class MacDemoWorkflowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Command-K opens the palette, typing searches it, Escape closes it.
  @MainActor
  func testPaletteOpensSearchesAndCloses() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    let palette = live.element("command-palette", in: app)
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(palette.waitForExistence(timeout: 10), "no palette")
    app.typeText("design")
    live.assertRunning(app, "searching the palette")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(palette.waitForNonExistence(timeout: 10), "Escape left the palette open")
    live.assertRunning(app, "after closing the palette")
  }

  /// A sent message shows in the transcript, the demo agent starts replying, and Command-Period
  /// stops it. The sample sessions take no message (one is read-only, two wait on a request), so
  /// this starts its own.
  @MainActor
  func testSendingStreamsAReplyThatStopStops() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }

    let message = "UI check \(UUID().uuidString.prefix(6)) in detail"
    live.startDemoSession(message, in: app)
    let stop = live.element("composer-stop", in: app)
    XCTAssertTrue(stop.waitForExistence(timeout: 15), "the demo agent never started replying")
    app.typeKey(".", modifierFlags: .command)
    XCTAssertTrue(stop.waitForNonExistence(timeout: 15), "Command-Period did not stop the reply")
    live.assertRunning(app, "after stopping the reply")
  }

  /// Command-T, Command-W, Shift-Command-T, Control-Tab and Command-1 on the tab strip.
  @MainActor
  func testTabsOpenCloseReopenAndCycle() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let newTabs = live.tabs("newTab", in: app)
    let before = newTabs.count

    app.typeKey("t", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { newTabs.count == before + 1 }, "Command-T opened no tab")
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { newTabs.count == before }, "Command-W left the tab open")
    app.typeKey("t", modifierFlags: [.command, .shift])
    live.assertRunning(app, "after reopening a tab")

    app.typeKey("t", modifierFlags: .command)
    for _ in 0..<4 { app.typeKey(.tab, modifierFlags: .control) }
    for _ in 0..<4 { app.typeKey(.tab, modifierFlags: [.control, .shift]) }
    app.typeKey("1", modifierFlags: .command)
    XCTAssertTrue(
      live.element("transcript-demo-notes", in: app).waitForExistence(timeout: 10),
      "Command-1 did not select the chat tab")
    live.assertRunning(app, "after cycling tabs")
  }

  /// Shift-Command-Backslash shows every tab; Done closes it.
  @MainActor
  func testTabOverviewOpensAndCloses() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    app.typeKey("t", modifierFlags: .command)

    app.typeKey("\\", modifierFlags: [.command, .shift])
    let sheet = live.element("tab-overview-sheet", in: app)
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no tab overview")
    XCTAssertGreaterThanOrEqual(live.elements(prefix: "tab-overview-row-", in: app).count, 2)
    live.click(live.element("tab-overview-done", in: app), "Done")
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Done left the overview open")
    live.assertRunning(app, "after the tab overview")
  }

  /// Command-Backslash splits the window into two panes and joins them again; the pane keys move
  /// between them.
  @MainActor
  func testSplitViewOpensAndCloses() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    app.typeKey("t", modifierFlags: .command)

    let divider = live.element("tab-split-divider", in: app)
    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(divider.waitForExistence(timeout: 10), "Command-Backslash did not split")
    app.typeKey(.leftArrow, modifierFlags: [.command, .option])
    app.typeKey(.rightArrow, modifierFlags: [.command, .option])
    live.assertRunning(app, "moving between panes")
    app.typeKey("\\", modifierFlags: .command)
    XCTAssertTrue(divider.waitForNonExistence(timeout: 10), "the split did not close")
    live.assertRunning(app, "after the split")
  }

  /// Control-Command-S hides and shows the sidebar; Option-Command-I the inspector.
  @MainActor
  func testSidebarAndInspectorToggle() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    let sidebar = live.element("sidebar", in: app)
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10))
    app.typeKey("s", modifierFlags: [.command, .control])
    XCTAssertTrue(sidebar.waitForNonExistence(timeout: 10), "the sidebar did not hide")
    app.typeKey("s", modifierFlags: [.command, .control])
    XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "the sidebar did not come back")

    let inspector = live.element("session-inspector", in: app)
    let shown = inspector.exists
    app.typeKey("i", modifierFlags: [.command, .option])
    XCTAssertTrue(
      live.waitUntil { inspector.exists != shown }, "Option-Command-I did not toggle the inspector")
    app.typeKey("i", modifierFlags: [.command, .option])
    XCTAssertTrue(live.waitUntil { inspector.exists == shown }, "the inspector did not toggle back")
    live.assertRunning(app, "after the sidebar and inspector")
  }

  /// Command-Slash lists the keyboard shortcuts; Escape closes the list.
  @MainActor
  func testKeyboardShortcutsSheet() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    let sheet = live.element("keyboard-shortcuts", in: app)
    app.typeKey("/", modifierFlags: .command)
    XCTAssertTrue(sheet.waitForExistence(timeout: 10), "no shortcuts list")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Escape left the shortcuts list open")
    live.assertRunning(app, "after the shortcuts list")
  }

  /// Command-Comma opens Settings; every tab of its toolbar opens; Command-W closes it.
  @MainActor
  func testSettingsOpensEveryTab() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let windows = app.windows.count

    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { app.windows.count == windows + 1 }, "no Settings window")
    let settings = app.windows.element(boundBy: 0)
    let tabs = settings.toolbars.buttons.allElementsBoundByIndex
    XCTAssertFalse(tabs.isEmpty, "Settings has no tabs\n\(settings.debugDescription)")
    for tab in tabs where tab.isHittable {
      tab.click()
      live.assertRunning(app, "on the Settings tab \(tab.label)")
    }
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { app.windows.count == windows }, "Settings did not close")
  }

  /// Shift-Command-N opens a second window; Shift-Command-W closes it.
  @MainActor
  func testNewWindowOpensAndCloses() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    let windows = app.windows.count

    app.typeKey("n", modifierFlags: [.command, .shift])
    XCTAssertTrue(live.waitUntil(timeout: 20) { app.windows.count == windows + 1 }, "no new window")
    live.assertRunning(app, "with two windows")
    app.typeKey("w", modifierFlags: [.command, .shift])
    XCTAssertTrue(live.waitUntil { app.windows.count == windows }, "the new window did not close")
    live.assertRunning(app, "after closing the window")
  }

  /// Zoom in, out and back, and Find in the transcript.
  @MainActor
  func testZoomAndFind() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    for _ in 0..<3 { app.typeKey("=", modifierFlags: .command) }
    live.assertRunning(app, "zoomed in")
    for _ in 0..<5 { app.typeKey("-", modifierFlags: .command) }
    live.assertRunning(app, "zoomed out")
    app.typeKey("0", modifierFlags: .command)
    app.typeKey("f", modifierFlags: .command)
    app.typeText("the")
    app.typeKey("g", modifierFlags: .command)
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeKey(.escape, modifierFlags: [])
    live.assertRunning(app, "after Find")
  }

  /// A draft stays with its session while another session is shown. Both sessions are writable;
  /// demo-notes is read-only and has no composer.
  @MainActor
  func testDraftsStayWithTheirSession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)

    let draft = "draft \(UUID().uuidString.prefix(6))"
    let input = live.element("composer-input", in: app)
    live.click(input, "the composer")
    app.typeText(draft)
    live.openDemo("demo-design", in: app)
    XCTAssertFalse(
      (input.value as? String ?? "").contains(draft), "the draft followed into another session")
    live.openDemo("demo-question", in: app)
    XCTAssertTrue(
      live.waitUntil { (input.value as? String ?? "").contains(draft) },
      "the draft was lost: \(input.value ?? "nil")")
    live.assertRunning(app, "after switching sessions")
  }
}
