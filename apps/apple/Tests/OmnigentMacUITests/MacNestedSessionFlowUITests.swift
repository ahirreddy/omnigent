import XCTest

/// Nested agents on the live local server: Add nested agent from the seeded fixture session's row
/// opens the composer beside it with a provisional row in the sidebar, the session it starts sits
/// nested under the fixture, the family collapses and expands, a member offers no Pin or project,
/// it leaves the nest and joins it again from Move session, Nests, and Option-Command-A on the
/// member opens the composer again for a peer, whose draft row stays after leaving it.
final class MacNestedSessionFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testAddNestedAgentNestsANewSessionUnderItsSource() throws {
    let live = MacLiveUITestSupport(self)
    let fixture = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    let fixtureRow = live.row(fixture, in: app)
    XCTAssertTrue(fixtureRow.appears(within: 30), "the fixture session is not in the sidebar")

    openComposer(beside: fixtureRow, live, app)
    let draft = draftRow(live, app)
    live.shot(app, "nested-composer")

    // Start it on the seeded mock agent: the session opens and nests under the fixture.
    chooseMockAgent(live, app)
    live.send("Plan the next step", in: app)
    let transcript = live.anyTranscript(in: app)
    XCTAssertTrue(transcript.appears(within: 30), "the nested session did not open")
    let member = String(transcript.identifier.dropFirst("transcript-".count))
    XCTAssertNotEqual(member, fixture)
    deleteAfterTheTest(member, on: live.server)
    let memberRow = live.row(member, in: app)
    XCTAssertTrue(memberRow.appears(within: 30), "the new session has no row")
    XCTAssertTrue(draft.disappears(within: 30), "the provisional row stayed beside the real one")
    XCTAssertTrue(
      live.waitUntil { isNested(memberRow, under: fixtureRow) },
      "the member is not right below the fixture: \(memberRow.frame) vs \(fixtureRow.frame)")
    live.shot(app, "nested-member")

    toggleFamily(of: fixture, hiding: memberRow, live, app)
    checkMenus(member: memberRow, representative: fixtureRow, live, app)

    // Move session, Nests: the server takes the member out of the nest, then back in.
    choose(["Move session", "Nests", "Remove from nest"], inMenuOf: memberRow, live, app)
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { !isNested(memberRow, under: fixtureRow) },
      "Remove from nest left the member under the fixture")
    live.shot(app, "nested-member-removed")
    choose(["Move session", "Nests", "UI test fixture"], inMenuOf: memberRow, live, app)
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { isNested(memberRow, under: fixtureRow) },
      "joining the fixture's nest did not nest the member under it")

    // Option-Command-A on the open member opens the composer for a peer. Leaving keeps its
    // draft row, which reopens the composer; Delete Draft drops it.
    live.clickTitle(of: memberRow, "the member row")
    XCTAssertTrue(transcript.appears(within: 15), "the member is not open")
    app.typeKey("a", modifierFlags: [.command, .option])
    let subtitle = live.element("new-session-subtitle", in: app)
    XCTAssertTrue(subtitle.appears(within: 15), "Option-Command-A opened no nested composer")
    XCTAssertTrue(draft.appears(within: 10), "no provisional row for the peer")
    live.shot(app, "peer-composer")
    live.clickTitle(of: memberRow, "the member row")
    XCTAssertTrue(transcript.appears(within: 15), "the member did not open again")
    XCTAssertTrue(draft.exists, "leaving the composer dropped its draft row")
    live.clickTitle(of: draft, "the draft row")
    XCTAssertTrue(subtitle.appears(within: 15), "the draft row did not reopen its composer")
    choose(["Delete Draft"], inMenuOf: draft, live, app)
    XCTAssertTrue(draft.disappears(within: 10), "Delete Draft kept the draft row")
    live.assertRunning(app, "after the nested flow")
  }

  /// Chooses Add nested agent, which leads `row`'s menu, and checks the composer it opens.
  @MainActor
  private func openComposer(
    beside row: XCUIElement, _ live: MacLiveUITestSupport, _ app: XCUIApplication
  ) {
    let menu = openMenu(of: row, live, app)
    XCTAssertEqual(firstTitle(of: menu), "Add nested agent", "the menu: \(titles(of: menu))")
    live.clickMenuItem("Add nested agent", in: app)
    let subtitle = live.element("new-session-subtitle", in: app)
    XCTAssertTrue(subtitle.appears(within: 15), "no nested composer\n\(app.debugDescription)")
    XCTAssertTrue(
      live.waitUntil {
        shownText(of: subtitle).contains("A new conversation alongside UI test fixture")
      }, "the subtitle says \(shownText(of: subtitle))")
    XCTAssertTrue(
      live.text(containing: "Add nested agent", in: app).appears(within: 5), "no heading")
  }

  /// The composer's provisional "New nested agent" row, once the sidebar shows it.
  @MainActor
  private func draftRow(_ live: MacLiveUITestSupport, _ app: XCUIApplication) -> XCUIElement {
    let draft = live.elements(prefix: "session-row-nested-draft-", in: app).firstMatch
    XCTAssertTrue(draft.appears(within: 10), "no New nested agent row in the sidebar")
    XCTAssertTrue(
      live.text(containing: "New nested agent", in: app).appears(within: 5),
      "the draft row has no New nested agent title")
    return draft
  }

  /// The head row's chevron collapses the family, hiding `memberRow`, and expands it again.
  @MainActor
  private func toggleFamily(
    of head: String, hiding memberRow: XCUIElement, _ live: MacLiveUITestSupport,
    _ app: XCUIApplication
  ) {
    let toggle = live.element("session-family-toggle-\(head)", in: app)
    XCTAssertTrue(toggle.appears(within: 10), "the fixture row has no family chevron")
    XCTAssertEqual(toggle.label, "Collapse session family")
    toggle.click()
    XCTAssertTrue(memberRow.disappears(within: 10), "collapsing left the member showing")
    XCTAssertTrue(live.waitUntil { toggle.label == "Expand session family" }, toggle.label)
    toggle.click()
    XCTAssertTrue(memberRow.appears(within: 10), "expanding did not bring the member back")
  }

  /// A member can add a peer and move between nests, but has no Pin or project; its
  /// representative keeps Pin.
  @MainActor
  private func checkMenus(
    member: XCUIElement, representative: XCUIElement, _ live: MacLiveUITestSupport,
    _ app: XCUIApplication
  ) {
    let memberMenu = openMenu(of: member, live, app)
    let memberTitles = titles(of: memberMenu)
    XCTAssertEqual(firstTitle(of: memberMenu), "Add nested agent")
    for refused in ["Pin", "Unpin", "Add to project"] {
      XCTAssertFalse(memberTitles.contains(refused), "a member offers \(refused): \(memberTitles)")
    }
    XCTAssertTrue(memberTitles.contains("Move session"), "no Move session: \(memberTitles)")
    app.typeKey(.escape, modifierFlags: [])
    let headTitles = titles(of: openMenu(of: representative, live, app))
    XCTAssertTrue(headTitles.contains("Pin"), "the fixture lost Pin: \(headTitles)")
    app.typeKey(.escape, modifierFlags: [])
  }

  /// Right-clicks `row` and chooses `path` through its submenus. The pointer enters each
  /// submenu beside the row that opened it, so it doesn't cross the menu's other rows.
  @MainActor
  private func choose(
    _ path: [String], inMenuOf row: XCUIElement, _ live: MacLiveUITestSupport,
    _ app: XCUIApplication
  ) {
    _ = openMenu(of: row, live, app)
    var opener: XCUIElement?
    for title in path {
      let items = app.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", title))
      guard let item = live.hittable(items) else {
        XCTFail("no menu item \(title)\n\(app.debugDescription)")
        return
      }
      if let opener {
        opener.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
          .withOffset(CGVector(dx: item.frame.midX - opener.frame.minX, dy: 0)).hover()
      }
      item.click()
      opener = item
    }
  }

  /// Right-clicks `row` and returns its context menu once it shows.
  @MainActor
  private func openMenu(
    of row: XCUIElement, _ live: MacLiveUITestSupport, _ app: XCUIApplication
  ) -> XCUIElement {
    XCTAssertTrue(row.appears(within: 10), "\(row) is missing")
    row.rightClick()
    let menus = app.menus.containing(NSPredicate(format: "title == %@", "Copy Session ID"))
    guard let menu = live.hittable(menus) else {
      XCTFail("no context menu\n\(app.debugDescription)")
      return menus.firstMatch
    }
    return menu
  }

  /// The menu's own items' titles, top to bottom, without its submenus' items.
  @MainActor
  private func titles(of menu: XCUIElement) -> [String] {
    menu.children(matching: .menuItem).allElementsBoundByIndex.map(\.title)
  }

  @MainActor
  private func firstTitle(of menu: XCUIElement) -> String {
    menu.children(matching: .menuItem).element(boundBy: 0).title
  }

  /// Deletes the session the flow created once it ends, pass or fail, so the fixture's family
  /// holds no members from earlier runs (a reseeded fixture keeps its id, and the server refuses
  /// to start a family under an id that old members still use).
  private func deleteAfterTheTest(_ sessionID: String, on server: String) {
    guard let url = URL(string: "\(server)/v1/sessions/\(sessionID)") else {
      XCTFail("no URL for \(sessionID) on \(server)")
      return
    }
    addTeardownBlock {
      var request = URLRequest(url: url)
      request.httpMethod = "DELETE"
      let (_, response) = try await URLSession.shared.data(for: request)
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      XCTAssertTrue((200..<300).contains(status), "deleting \(sessionID) answered \(status)")
    }
  }

  /// The element's label, or its value where it holds the text as a macOS static text does.
  @MainActor
  private func shownText(of element: XCUIElement) -> String {
    element.label.isEmpty ? (element.value as? String ?? "") : element.label
  }

  /// Whether `member` is the row right below `head`. Its indent is drawn, not in its frame: the
  /// family chevron collapsing it shows it belongs to the head.
  @MainActor
  private func isNested(_ member: XCUIElement, under head: XCUIElement) -> Bool {
    guard member.exists, head.exists else { return false }
    let gap = member.frame.minY - head.frame.maxY
    return gap >= -1 && gap < member.frame.height
  }

  /// Picks the seeded mock agent (`Tools/mock-model.py`) from the custom agents' Other… submenu:
  /// it answers from the local mock model, where another agent may open a login page instead.
  @MainActor
  private func chooseMockAgent(_ live: MacLiveUITestSupport, _ app: XCUIApplication) {
    let chip = live.element("composer-configuration", in: app)
    XCTAssertTrue(
      live.waitUntil(timeout: 15) {
        chip.exists && chip.isEnabled && chip.label.hasPrefix("Agent, ")
      }, "the composer chose no agent: \(chip.label)")
    live.click(chip, "the agent picker")
    let mockAgent = app.menuItems.matching(NSPredicate(format: "title == %@", Self.mockAgentName))
    let submenus = app.menuItems.matching(
      NSPredicate(format: "title BEGINSWITH %@", "Other\u{2026}"))
    // The custom agents' submenu follows the other harnesses' one.
    for submenu in submenus.allElementsBoundByIndex.reversed()
    where submenu.isHittable && live.hittable(mockAgent, timeout: 1) == nil {
      submenu.hover()
    }
    guard let item = live.hittable(mockAgent) else {
      XCTFail("no \(Self.mockAgentName) agent in the picker\n\(app.debugDescription)")
      return
    }
    item.click()
    let chosen = live.waitUntil { chip.label.contains(Self.mockAgentName) }
    XCTAssertTrue(chosen, "the composer chose \(chip.label)")
  }

  /// The mock agent's name, as `Tools/mock-model.py` installs it.
  private static let mockAgentName = "mock-model"
}
