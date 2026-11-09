import XCTest

/// The Settings window: every tab shows its own pane, and a changed value survives a relaunch.
final class MacSettingsFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Each toolbar tab shows a pane recognizable by something of its own.
  @MainActor
  func testEverySettingsTabShowsItsPane() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let settings = openSettings(live, app)

    let panes: [(tab: String, content: XCUIElement)] = [
      ("General", live.element("settings.submit-with-command-return", in: app)),
      ("Notifications", live.element("settings.notifications.play-sound", in: app)),
      ("Appearance", live.element("settings.appearance", in: app)),
      ("Terminal", live.element("settings.terminal-font-family", in: app)),
      ("Phone", live.text(containing: "iPhone", in: app)),
      ("Servers", live.element("server-settings", in: app)),
      ("Local Server", live.text(containing: "Start the server when Omnigent opens", in: app)),
      ("Advanced", live.text(containing: "Reset Window Position", in: app)),
    ]
    for pane in panes {
      live.click(settings.toolbars.buttons[pane.tab], "the \(pane.tab) tab")
      XCTAssertTrue(
        pane.content.waitForExistence(timeout: 10), "the \(pane.tab) tab shows the wrong pane")
    }
  }

  /// A setting changed in Settings is still changed after quitting and relaunching.
  @MainActor
  func testChangedSettingSurvivesRelaunch() {
    let live = MacLiveUITestSupport(self)
    var app = live.launchDemo()
    defer { app.terminate() }
    let before = togglePlaySound(live, app, click: true)
    live.quit(app)

    app = live.launchDemo()
    let after = togglePlaySound(live, app, click: false)
    XCTAssertNotEqual(before, after, "the changed setting did not survive the relaunch")

    // The preference outlives the app, so put it back for the next flow.
    _ = togglePlaySound(live, app, click: true, reopen: false)
  }

  /// Opens Settings with Command-Comma and returns its window.
  @MainActor
  private func openSettings(_ live: MacLiveUITestSupport, _ app: XCUIApplication) -> XCUIElement {
    live.waitForDemoSessions(in: app)
    let windows = app.windows.count
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { app.windows.count == windows + 1 }, "no Settings window")
    return app.windows.element(boundBy: 0)
  }

  /// The Play sound toggle's value before an optional click, from the Notifications tab.
  @MainActor
  private func togglePlaySound(
    _ live: MacLiveUITestSupport, _ app: XCUIApplication, click: Bool, reopen: Bool = true
  ) -> String {
    if reopen {
      let settings = openSettings(live, app)
      live.click(settings.toolbars.buttons["Notifications"], "the Notifications tab")
    }
    let toggle = live.element("settings.notifications.play-sound", in: app)
    XCTAssertTrue(toggle.waitForExistence(timeout: 10), "no Play sound toggle")
    let value = String(describing: toggle.value ?? "")
    if click { toggle.click() }
    return value
  }
}
