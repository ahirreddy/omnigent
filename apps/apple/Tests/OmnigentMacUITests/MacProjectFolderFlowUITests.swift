import XCTest

/// A project folder's Show more row on the local server, clicked with the real pointer: on its
/// text, on the gap, on the Needs you pill of the requests it hides and near the row's top and
/// bottom edges, while the list updates.
final class MacProjectFolderFlowUITests: XCTestCase {
  /// Where a click on Show more lands.
  private enum Place: String {
    case pill
    case gap
    case pillAfterItsTooltip = "pill after its tooltip shows"
    case text
    case topEdge = "row's top edge"
    case bottomEdge = "row's bottom edge"

    /// The point in Show more's outline `row`: the pill, about 60 points wide, trails the row,
    /// the gap is before it, and the text starts a step or two in.
    func point(in row: CGRect) -> CGPoint {
      switch self {
      case .pill, .pillAfterItsTooltip: CGPoint(x: row.maxX - 30, y: row.midY)
      case .gap: CGPoint(x: row.maxX - 80, y: row.midY)
      case .text: CGPoint(x: row.minX + 48, y: row.midY)
      case .topEdge: CGPoint(x: row.maxX - 80, y: row.minY + 2)
      case .bottomEdge: CGPoint(x: row.maxX - 80, y: row.maxY - 2)
      }
    }
  }

  /// The clicks' places in turn, one an expansion.
  private static let places: [Place] = [
    .pill, .gap, .pillAfterItsTooltip, .topEdge, .pill, .bottomEdge, .text,
  ]
  /// A page listed and three under Show more: one click lists all.
  private static let sessionCount = 13
  /// The newest sessions, renamed over and over; the others wait on a request.
  private static let renamedCount = 3

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A folder of thirteen, ten waiting on a request: each expansion lists a page, and every click
  /// on Show more lists the rest wherever it lands, across renames that stream in and the
  /// sidebar's minute-long reconcile.
  @MainActor
  func testShowMoreTakesEveryClickBesideANeedsYouPill() async throws {
    let live = MacLiveUITestSupport(self)
    let seeded = try await seedFolder(live)
    let server = live.server
    let (name, renamed) = (seeded.name, Array(seeded.sessions.suffix(Self.renamedCount)))
    let updates = Task.detached {
      for tick in 1... {
        guard !Task.isCancelled else { return }
        await renameSession(
          renamed[tick % renamed.count], to: "\(name) renamed \(tick)", on: server)
        try? await Task.sleep(for: .milliseconds(300))
      }
    }
    defer { updates.cancel() }

    let app = live.launch()
    defer { app.terminate() }
    let folder = live.element("sidebar-project-\(seeded.project)", in: app)
    XCTAssertTrue(folder.appears(within: 30), "the folder is not listed")
    let showMore = live.element("project-show-more-\(seeded.project)", in: app)
    let rows = app.descendants(matching: .any).matching(
      NSPredicate(format: "identifier IN %@", seeded.sessions.map { "session-row-\($0)" }))
    var tally = Tally()
    let start = Date()
    // Past the reconcile, which reads every list again after a minute.
    while tally.clicks < 8 || Date().timeIntervalSince(start) < 75 {
      try toggle(folder, live: live, app: app)
      XCTAssertTrue(
        live.waitUntil(timeout: 15) { rows.count == 5 }, "the folder lists \(rows.count)")
      if tally.clicks == 0 { live.shot(app, "the folder open") }
      try await showAll(showMore, rows: rows, tally: &tally, live: live, app: app)
      try toggle(folder, live: live, app: app)
      XCTAssertTrue(
        live.waitUntil(timeout: 10) { !rows.firstMatch.exists }, "the folder stayed open")
    }
    XCTAssertGreaterThan(tally.clicksBesidePill, 0, "Show more never carried a Needs you pill")
    XCTAssertEqual(
      tally.misses, [], "Show more missed \(tally.misses.count) of \(tally.clicks) clicks")
  }

  /// The clicks on Show more so far, and the ones that listed nothing.
  private struct Tally {
    var clicks = 0
    var clicksBesidePill = 0
    var misses: [String] = []
  }

  /// A new project's id and name, and its sessions' ids, oldest first.
  private struct SeededFolder {
    let name: String
    let project: String
    let sessions: [String]
  }

  /// A project of thirteen, all but the newest three waiting on a request, so that the three
  /// under Show more wait on one. All are deleted once the test ends.
  @MainActor
  private func seedFolder(_ live: MacLiveUITestSupport) async throws -> SeededFolder {
    let fixture = try await live.serverJSON("GET", "/v1/sessions/\(try live.fixtureSession())")
    let agent = try XCTUnwrap(fixture["agent_id"] as? String, "\(fixture)")
    let (projectID, name) = try await live.flowProject("show more")
    var ids: [String] = []
    for index in 0..<Self.sessionCount {
      let created = try await live.serverJSON(
        "POST", "/v1/sessions",
        body: ["agent_id": agent, "project_id": projectID, "title": "\(name) \(index + 1)"])
      let id = try XCTUnwrap(created["id"] as? String, "\(created)")
      live.removeAfterTheTest("/v1/sessions/\(id)")
      ids.append(id)
      if index < Self.sessionCount - Self.renamedCount { try await ask(id, live: live) }
    }
    return SeededFolder(name: name, project: projectID, sessions: ids)
  }

  /// Clicks Show more until every session shows, noting each click that listed none.
  @MainActor
  private func showAll(
    _ showMore: XCUIElement, rows: XCUIElementQuery, tally: inout Tally,
    live: MacLiveUITestSupport, app: XCUIApplication
  ) async throws {
    // By the count of rows: Show more's row stays a moment after the last click lists all.
    while rows.count < Self.sessionCount {
      XCTAssertTrue(showMore.appears(within: 5), "no Show more with \(rows.count) listed")
      let listed = rows.count
      let place = Self.places[tally.clicks % Self.places.count]
      // Pointer events go to the window in front: another app's window must not take them.
      app.activate()
      let row = try revealShowMore(below: rows, live: live, app: app)
      if hasPill(showMore, in: row, app: app) { tally.clicksBesidePill += 1 }
      let point = place.point(in: row)
      try await click(point, in: app, waitingForTooltip: place == .pillAfterItsTooltip)
      tally.clicks += 1
      let expected = min(listed + 5, Self.sessionCount)
      if !live.waitUntil(timeout: 3, { rows.count >= expected }) {
        tally.misses.append(
          "click \(tally.clicks), on the \(place.rawValue) at \(point) in \(row), \(listed) listed")
        live.shot(app, "missed click \(tally.clicks)")
        try await click(Place.text.point(in: row), in: app, waitingForTooltip: false)
        XCTAssertTrue(
          live.waitUntil(timeout: 5) { rows.count >= expected }, "Show more took no click")
      }
    }
    XCTAssertTrue(showMore.disappears(within: 5), "Show more stayed with every session listed")
  }

  /// Show more's outline row, scrolled clear of the window's bottom edge and the Dock below it.
  /// Show more's own frame reads empty while it is below the window: the rows above place it.
  @MainActor
  private func revealShowMore(
    below rows: XCUIElementQuery, live: MacLiveUITestSupport, app: XCUIApplication
  ) throws -> CGRect {
    let window = app.windows.firstMatch
    let bottom = window.frame.maxY - 60
    var row = try Self.showMoreRow(below: rows)
    let pointer = window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: row.midX - window.frame.minX, dy: window.frame.height / 2))
    for _ in 0..<20 where row.maxY > bottom {
      let before = row.minY
      pointer.scroll(byDeltaX: 0, deltaY: -40)
      // A frame read straight after a scroll can be the old one: wait for it to land.
      _ = live.waitUntil(timeout: 1) { (try? Self.showMoreRow(below: rows))?.minY != before }
      row = try Self.showMoreRow(below: rows)
    }
    return row
  }

  /// Show more's outline row, on screen: it follows the last listed session's, a row's pitch
  /// apart, as wide. A row reports its content's frame, centered in the row.
  @MainActor
  private static func showMoreRow(below rows: XCUIElementQuery) throws -> CGRect {
    let listed = rows.allElementsBoundByIndex.map(\.frame).sorted { $0.minY < $1.minY }
    let above = try XCTUnwrap(listed.last, "no session listed above Show more")
    let pitch = above.minY - (listed.dropLast().last ?? above).minY
    return CGRect(
      x: above.minX, y: above.maxY + (pitch - above.height) / 2, width: above.width,
      height: pitch)
  }

  /// Whether Show more's `row` carries the pill: in Show more's label, or apart from it.
  @MainActor
  private func hasPill(_ showMore: XCUIElement, in row: CGRect, app: XCUIApplication) -> Bool {
    showMore.label.contains("Needs you")
      || app.descendants(matching: .any)
        .matching(NSPredicate(format: "label BEGINSWITH %@", "Needs you"))
        .allElementsBoundByIndex.contains {
          row.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
        }
  }

  /// Clicks the window at `point` on screen, first resting there until a tooltip would show.
  @MainActor
  private func click(_ point: CGPoint, in app: XCUIApplication, waitingForTooltip: Bool)
    async throws
  {
    let window = app.windows.firstMatch
    let target = window.coordinate(withNormalizedOffset: .zero)
      .withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
    if waitingForTooltip {
      target.hover()
      try await Task.sleep(for: .seconds(2))
    }
    target.click()
  }

  /// Opens or closes the folder on its expand button, first bringing the row back where the list
  /// scrolled it away above.
  @MainActor
  private func toggle(_ folder: XCUIElement, live: MacLiveUITestSupport, app: XCUIApplication)
    throws
  {
    app.activate()
    let window = app.windows.firstMatch
    let sidebar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
    for _ in 0..<20 where !folder.exists {
      sidebar.scroll(byDeltaX: 0, deltaY: 80)
      _ = live.waitUntil(timeout: 1) { folder.exists }
    }
    live.scrollIntoView(folder)
    let id = folder.identifier.replacingOccurrences(
      of: "sidebar-project-", with: "sidebar-project-toggle-")
    let button = app.buttons[id].firstMatch
    XCTAssertTrue(button.exists, "no expand button on the folder\n\(app.debugDescription)")
    button.click()
  }

  /// Asks a question in `sessionID`, so it needs you until the test ends.
  @MainActor
  private func ask(_ sessionID: String, live: MacLiveUITestSupport) async throws {
    let asked = try await live.serverJSON(
      "POST", "/v1/sessions/\(sessionID)/events",
      body: [
        "type": "mcp_elicitation",
        "data": [
          "message": "Keep the folder open?",
          "requestedSchema": [
            "type": "object",
            "properties": ["answer": ["type": "string", "enum": ["Yes", "No"]]],
          ],
        ],
      ])
    XCTAssertNotNil(asked["elicitation_id"] as? String, "no request: \(asked)")
  }
}

/// Renames a session, which the server streams to the app; a failed rename is one fewer update.
private func renameSession(_ sessionID: String, to title: String, on server: String) async {
  guard let url = URL(string: "\(server)/v1/sessions/\(sessionID)"),
    let body = try? JSONSerialization.data(withJSONObject: ["title": title])
  else { return }
  var request = URLRequest(url: url)
  request.httpMethod = "PATCH"
  request.setValue("application/json", forHTTPHeaderField: "Content-Type")
  request.httpBody = body
  _ = try? await URLSession.shared.data(for: request)
}
