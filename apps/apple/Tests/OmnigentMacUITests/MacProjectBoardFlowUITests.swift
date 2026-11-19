import XCTest

/// A project's board on the local server, with the real pointer: the project's sidebar row opens
/// it, a card dragged between Unread and Done marks it read or unread, and the board's floating
/// composer starts a session filed in the project.
final class MacProjectBoardFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  @MainActor
  func testTheBoardOpensFromItsRowMovesCardsAndStartsASession() async throws {
    let live = MacLiveUITestSupport(self)
    let (projectID, sessions) = try await seedProject(live)
    let app = live.launch()
    defer { app.terminate() }

    // A click on the project's row opens its board and leaves the folder closed.
    let folder = live.element("sidebar-project-\(projectID)", in: app)
    XCTAssertTrue(folder.appears(within: 30), "the project is not listed")
    live.clickTitle(of: folder, "the project's row")
    let board = live.element("project-board", in: app)
    XCTAssertTrue(board.appears(within: 15), "the row did not open the board")
    let cardID = "project-board-card-\(sessions[0])"
    let card = live.element(cardID, in: app)
    XCTAssertTrue(card.appears(within: 20), "the project's session has no card")
    XCTAssertFalse(live.row(sessions[0], in: app).exists, "the row expanded the folder")
    live.shot(app, "the board")

    // A card dragged between Unread and Done moves there, and back.
    let unread = live.element("project-board-lane-unread", in: app)
    let done = live.element("project-board-lane-done", in: app)
    let isIn = { (lane: XCUIElement) in lane.descendants(matching: .any)[cardID].exists }
    XCTAssertTrue(
      live.waitUntil(timeout: 15) { isIn(unread) || isIn(done) },
      "the card is in neither Unread nor Done\n\(app.debugDescription)")
    let (from, to) = isIn(done) ? (done, unread) : (unread, done)
    reveal([unread, done], in: app)
    drag(card, to: to)
    XCTAssertTrue(live.waitUntil(timeout: 15) { isIn(to) }, "the drop did not move the card")
    live.shot(app, "the card dropped")
    drag(card, to: from)
    XCTAssertTrue(live.waitUntil(timeout: 15) { isIn(from) }, "the card did not move back")

    // New Session floats the composer over the board; a start files the session in the project
    // and stays on the board.
    let cards = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "project-board-card-"))
    let before = cards.count
    live.click(live.element("project-board-new-session", in: app), "New Session")
    let composer = live.element("project-board-composer", in: app)
    XCTAssertTrue(composer.appears(within: 10), "New Session did not show the composer")
    live.shot(app, "the board's composer")
    live.send("Started from the board", in: app)
    XCTAssertTrue(composer.disappears(within: 30), "the composer stayed after the start")
    XCTAssertTrue(
      live.waitUntil(timeout: 30) { cards.count > before }, "the new session has no card")
    XCTAssertTrue(board.exists, "starting a session left the board")
    live.shot(app, "the started session's card")
  }

  /// A new project with two idle sessions of the fixture's agent, all removed once the test
  /// ends.
  @MainActor
  private func seedProject(_ live: MacLiveUITestSupport) async throws -> (String, [String]) {
    let fixture = try await live.serverJSON("GET", "/v1/sessions/\(try live.fixtureSession())")
    let agent = try XCTUnwrap(fixture["agent_id"] as? String, "\(fixture)")
    let (projectID, name) = try await live.flowProject("board")
    var sessions: [String] = []
    for index in 1...2 {
      let created = try await live.serverJSON(
        "POST", "/v1/sessions",
        body: ["agent_id": agent, "project_id": projectID, "title": "\(name) card \(index)"])
      let id = try XCTUnwrap(created["id"] as? String, "\(created)")
      live.removeAfterTheTest("/v1/sessions/\(id)")
      sessions.append(id)
    }
    return (projectID, sessions)
  }

  /// Scrolls the lanes sideways until `lanes` are in the window: a narrow window shows three.
  @MainActor
  private func reveal(_ lanes: [XCUIElement], in app: XCUIApplication) {
    let window = app.windows.firstMatch
    let inside = { lanes.allSatisfy { window.frame.contains($0.frame) } }
    // Over the lanes in view: a lane off the window takes no scroll.
    let pointer = window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.8))
    for step in [-120.0, 120.0] {
      for _ in 0..<12 where !inside() {
        let before = lanes[0].frame.minX
        pointer.scroll(byDeltaX: step, deltaY: 0)
        if lanes[0].frame.minX == before { break }
      }
    }
    XCTAssertTrue(inside(), "Unread and Done are not both in the window")
  }

  /// Drags `card` by its title onto the middle of `lane`, by points: a card in a lane's scroll
  /// view reads as not hittable to an element drag.
  @MainActor
  private func drag(_ card: XCUIElement, to lane: XCUIElement) {
    let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.25))
    let end = lane.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
    start.press(forDuration: 0.5, thenDragTo: end)
  }
}
