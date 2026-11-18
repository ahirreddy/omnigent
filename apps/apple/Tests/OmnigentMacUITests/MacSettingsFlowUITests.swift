import XCTest

/// Settings, a page of the window: every category shows its own pane, a changed value survives a
/// relaunch, and leaving finds the window as it was.
final class MacSettingsFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// Each category in the sidebar shows a pane recognizable by something of its own.
  @MainActor
  func testEverySettingsTabShowsItsPane() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    openSettings(live, app)

    let panes: [(category: String, content: XCUIElement)] = [
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
      live.click(category(pane.category, live, app), "the \(pane.category) category")
      XCTAssertTrue(
        pane.content.appears(within: 10), "the \(pane.category) category shows the wrong pane")
    }
    live.shot(app, "settings-advanced")
  }

  /// On the live server, Settings › Servers offers Custom Agents (the server installs agents;
  /// no retired flag gates it) and Sessions' title instructions, and each pane opens.
  @MainActor
  func testServerSettingsOfferCustomAgentsAndTitleInstructions() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    app.typeKey(",", modifierFlags: .command)
    live.click(category("Servers", live, app), "the Servers category")
    let agents = live.element("server-settings-pane-customAgents", in: app)
    live.click(agents, "the Custom Agents pane", timeout: 20)
    XCTAssertTrue(
      live.element("custom-agent-create", in: app).appears(within: 20),
      "Custom Agents shows no Create")
    live.click(live.element("server-settings-pane-sessions", in: app), "the Sessions pane")
    XCTAssertTrue(
      live.element("settings.session-title-instructions", in: app).appears(within: 20),
      "Sessions shows no title instructions")
    live.shot(app, "settings-server-sessions")
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

  /// From a conversation with a draft: the gear shows Settings over the whole window, two
  /// categories open, a setting changes, and Back finds the conversation, its tab and the draft.
  @MainActor
  func testSettingsLeavesTheConversationAsItWas() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)
    let draft = "draft \(UUID().uuidString.prefix(6))"
    live.focusComposer(in: app)
    app.typeText(draft)
    let transcript = live.element("transcript-demo-question", in: app)
    let row = live.row("demo-question", in: app)
    let window = app.windows.firstMatch
    let (windows, tabs, title) = (app.windows.count, live.tabs("chat", in: app).count, window.title)
    let transcriptFrame = transcript.frame

    live.click(live.element("sidebar-settings", in: app), "the sidebar's Settings button")
    let back = live.element("settings-back", in: app)
    XCTAssertTrue(back.appears(within: 10), "the gear showed no Settings page")
    XCTAssertEqual(app.windows.count, windows, "Settings opened another window")
    XCTAssertTrue(live.waitUntil { window.title == "Settings" }, "the title is \(window.title)")
    XCTAssertFalse(transcript.exists, "the conversation shows through Settings")
    XCTAssertFalse(row.exists, "the session sidebar shows through Settings")
    XCTAssertEqual(live.tabs("chat", in: app).count, 0, "the tab strip stayed over Settings")

    live.click(category("Appearance", live, app), "the Appearance category")
    XCTAssertTrue(live.element("settings.appearance", in: app).appears(within: 10), "no Appearance")
    live.shot(app, "settings-appearance")
    live.click(category("Notifications", live, app), "the Notifications category")
    let toggle = live.element("settings.notifications.play-sound", in: app)
    XCTAssertTrue(toggle.appears(within: 10), "no Play sound toggle")
    let sound = String(describing: toggle.value ?? "")
    toggle.click()
    XCTAssertTrue(
      live.waitUntil { String(describing: toggle.value ?? "") != sound },
      "the toggle did not change")
    // Keys typed on the page must not reach the composer under it.
    app.typeText("zz")

    live.click(back, "Back")
    XCTAssertTrue(transcript.appears(within: 10), "Back did not return to the conversation")
    XCTAssertTrue(row.exists, "the session sidebar did not come back")
    XCTAssertEqual(live.composerText(in: app), draft, "the draft changed under Settings")
    XCTAssertEqual(live.tabs("chat", in: app).count, tabs, "the session's tabs changed")
    XCTAssertTrue(live.waitUntil { window.title == title }, "the title stayed \(window.title)")
    XCTAssertTrue(
      live.waitUntil { transcript.frame == transcriptFrame },
      "the transcript moved: \(transcript.frame) from \(transcriptFrame)")
    live.assertRunning(app, "after leaving Settings")

    // Settings reopens where it was left; put the preference back for the next flow.
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(toggle.appears(within: 10), "Settings did not reopen on Notifications")
    toggle.click()
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(transcript.appears(within: 10), "Escape did not return to the conversation")
  }

  /// A long transcript scrolled away from its end is at the same place after Settings.
  @MainActor
  func testSettingsKeepsTheTranscriptsScrollPosition() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.pagedSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    let scrollViews = app.scrollViews.matching(identifier: "transcript-\(session)")
    XCTAssertTrue(scrollViews.firstMatch.appears(within: 10), "no transcript to scroll")
    let transcript = try XCTUnwrap(
      scrollViews.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width })
    transcript.scroll(byDeltaX: 0, deltaY: 500)
    // A message that is on screen now, found again later by its own text.
    let shown = try XCTUnwrap(
      visibleMessage(in: transcript, live, app), "no message on screen\n\(app.debugDescription)")
    let ownText = shown.label.isEmpty ? shown.value as? String ?? "" : shown.label
    let message = live.text(containing: ownText, in: app)
    // Older history can still be paging in above it.
    var place = message.frame
    XCTAssertTrue(
      live.waitUntil {
        let last = place
        place = message.frame
        return place == last
      }, "the transcript never came to rest")

    app.typeKey(",", modifierFlags: .command)
    let back = live.element("settings-back", in: app)
    XCTAssertTrue(back.appears(within: 10), "Command-Comma showed no Settings page")
    live.click(category("Terminal", live, app), "the Terminal category")
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(back.disappears(within: 10), "Command-Comma did not leave Settings")

    XCTAssertTrue(message.appears(within: 10), "the message left the screen")
    XCTAssertTrue(
      live.waitUntil { message.frame == place },
      "the transcript scrolled: \(message.frame) from \(place)")
  }

  /// A message inside `transcript` that is on screen now, by the text every seeded turn carries.
  @MainActor
  private func visibleMessage(
    in transcript: XCUIElement, _ live: MacLiveUITestSupport, _ app: XCUIApplication
  ) -> XCUIElement? {
    let types: [XCUIElement.ElementType] = [.staticText, .textView]
    let turns = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "label CONTAINS %@ OR (elementType IN %@ AND value CONTAINS %@)",
        argumentArray: ["(step ", types.map(\.rawValue), "(step "]))
    var found: XCUIElement?
    _ = live.waitUntil {
      let area = transcript.frame
      found = turns.allElementsBoundByIndex.first {
        $0.isHittable && area.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
      }
      return found != nil
    }
    return found
  }

  /// A category's row in the Settings sidebar.
  @MainActor
  private func category(
    _ title: String, _ live: MacLiveUITestSupport, _ app: XCUIApplication
  ) -> XCUIElement {
    live.element("settings-category-\(title)", in: app)
  }

  /// Opens Settings with Command-Comma: a page of the window, not a window of its own.
  @MainActor
  private func openSettings(_ live: MacLiveUITestSupport, _ app: XCUIApplication) {
    live.waitForDemoSessions(in: app)
    let windows = app.windows.count
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(
      live.element("settings-back", in: app).appears(within: 10),
      "Command-Comma showed no Settings page")
    XCTAssertEqual(app.windows.count, windows, "Settings opened another window")
  }

  /// The Play sound toggle's value before an optional click, from the Notifications category.
  @MainActor
  private func togglePlaySound(
    _ live: MacLiveUITestSupport, _ app: XCUIApplication, click: Bool, reopen: Bool = true
  ) -> String {
    if reopen {
      openSettings(live, app)
      live.click(category("Notifications", live, app), "the Notifications category")
    }
    let toggle = live.element("settings.notifications.play-sound", in: app)
    XCTAssertTrue(toggle.appears(within: 10), "no Play sound toggle")
    let value = String(describing: toggle.value ?? "")
    if click { toggle.click() }
    return value
  }
}
