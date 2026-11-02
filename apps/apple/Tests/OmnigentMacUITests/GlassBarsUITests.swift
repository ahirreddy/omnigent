import XCTest

/// The system bars over a long transcript against a live server: the titlebar's tab row and the
/// composer with the transcript scrolled under both, light and dark, in several palettes, split
/// beside a browser tab and with the window inactive. Screenshots are window-only attachments
/// named `glass-<palette>-<appearance>-<state>`.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_GLASS_SESSION_ID` (with
/// the `TEST_RUNNER_` prefix): a session long enough to scroll. `OMNIGENT_GLASS_PALETTES` picks
/// the palettes (`omni,nord` by default). Tabs are saved in a scratch directory.
final class GlassBarsUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testTranscriptScrollsUnderTheBars() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let server = environment["OMNIGENT_E2E_SERVER_URL"],
      let sessionID = environment["OMNIGENT_GLASS_SESSION_ID"]
    else {
      throw XCTSkip("Set TEST_RUNNER_OMNIGENT_E2E_SERVER_URL and _GLASS_SESSION_ID to run.")
    }
    let palettes = (environment["OMNIGENT_GLASS_PALETTES"] ?? "omni,nord")
      .split(separator: ",").map(String.init)
    for palette in palettes {
      for appearance in ["light", "dark"] {
        try capture(
          server: server, sessionID: sessionID, palette: palette, appearance: appearance,
          includesSplit: palette == palettes.first)
      }
    }
  }

  @MainActor
  private func capture(
    server: String, sessionID: String, palette: String, appearance: String, includesSplit: Bool
  ) throws {
    let tabs = FileManager.default.temporaryDirectory.appending(
      path: "omnigent-glass-uitest-\(UUID().uuidString)", directoryHint: .isDirectory)
    // Arguments are parsed as property lists; the stored palette is a JSON string, so quote twice.
    let app = XCUIApplication()
    app.launchArguments = [
      "-desktop.defaultServerURL", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentTabsDirectory", tabs.path, "-web-theme", appearance,
      "-omnigent:ui-theme-palette", #""\"\#(palette)\"""#,
    ]
    app.launch()
    defer { app.terminate() }
    let window = app.windows.firstMatch
    let name = "\(palette)-\(appearance)"

    let row = window.descendants(matching: .any)["session-row-\(sessionID)"]
    XCTAssertTrue(row.waitForExistence(timeout: 30), "the session list did not show \(sessionID)")
    let input = app.textViews["composer-input"]
    for _ in 0..<5 where !input.exists {
      row.click()
      _ = input.waitForExistence(timeout: 4)
    }
    XCTAssertTrue(input.waitForExistence(timeout: 20), "the conversation did not open")
    let transcript = window.scrollViews
      .matching(NSPredicate(format: "identifier BEGINSWITH 'transcript-'")).firstMatch
    XCTAssertTrue(transcript.waitForExistence(timeout: 10), "no transcript")
    // Let the transcript settle at the bottom, then read from the middle so text sits under
    // both bars.
    Thread.sleep(forTimeInterval: 2)
    save(window, "\(name)-bottom")
    transcript.scroll(byDeltaX: 0, deltaY: 900)
    Thread.sleep(forTimeInterval: 1)
    save(window, "\(name)-scrolled")

    // Another app in front: the window's inactive bars.
    let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    finder.activate()
    Thread.sleep(forTimeInterval: 1)
    save(window, "\(name)-inactive")
    app.activate()

    if includesSplit {
      app.typeKey("b", modifierFlags: [.command, .option])
      let leading = window.descendants(matching: .any)["tab-pane-leading"]
      for _ in 0..<3 where !leading.exists {
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Show Split View"].click()
        _ = leading.waitForExistence(timeout: 4)
      }
      XCTAssertTrue(leading.exists, "the split did not open")
      Thread.sleep(forTimeInterval: 2)
      save(window, "\(name)-split")
    }
  }

  @MainActor
  private func save(_ element: XCUIElement, _ name: String) {
    let attachment = XCTAttachment(screenshot: element.screenshot())
    attachment.name = "glass-\(name)"
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}
