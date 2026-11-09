import XCTest

/// A session's life in the sidebar on the offline demo server: open, rename, pin, archive,
/// unarchive and delete. demo-notes is read-only, so what changes a session acts on demo-question.
final class MacSessionFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// One click on a row opens that session, without entering rename.
  @MainActor
  func testSingleClickOpensASession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    // The window has settled once a first session has opened, so the next click must count.
    live.openDemo("demo-notes", in: app)

    live.row("demo-question", in: app).click()
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).waitForExistence(timeout: 10),
      "one click did not open the session")
    XCTAssertFalse(live.element("session-row-rename-field", in: app).exists, "it began a rename")
    XCTAssertFalse(live.element("transcript-demo-notes", in: app).exists, "the old session stayed")
  }

  /// A read-only session opens with a read-only bar and no composer.
  @MainActor
  func testReadOnlySessionHasNoComposer() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }

    live.openDemo("demo-notes", in: app)
    XCTAssertTrue(
      live.element("composer-read-only", in: app).waitForExistence(timeout: 10),
      "no read-only notice")
    XCTAssertFalse(live.composer(in: app).exists, "a read-only session offered a composer")
  }

  /// Rename in the row's context menu asks for a title, and the row shows it.
  @MainActor
  func testContextMenuRenamesASession() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let title = "Renamed \(UUID().uuidString.prefix(6))"

    live.contextMenu(live.row("demo-question", in: app), choose: "Rename\u{2026}", in: app)
    XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 10), "no rename prompt")
    app.typeKey("a", modifierFlags: .command)
    app.typeText(title)
    live.clickDialogButton("Rename", in: app)
    live.assertRow("demo-question", in: app, contains: title)
  }

  /// A double-click renames in place: Return saves.
  @MainActor
  func testDoubleClickRenamesInPlace() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let title = "Inline \(UUID().uuidString.prefix(6))"
    let row = live.row("demo-question", in: app)
    live.waitForDemoSessions(in: app)

    row.doubleClick()
    let field = live.element("session-row-rename-field", in: app)
    XCTAssertTrue(field.waitForExistence(timeout: 10), "a double-click began no rename")
    field.click()
    app.typeKey("a", modifierFlags: .command)
    app.typeText(title + "\r")
    XCTAssertTrue(field.waitForNonExistence(timeout: 10), "Return left the field open")
    live.assertRow("demo-question", in: app, contains: title)
  }

  /// Escape abandons an in-place rename and keeps the old title.
  @MainActor
  func testEscapeCancelsAnInPlaceRename() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let row = live.row("demo-question", in: app)
    live.waitForDemoSessions(in: app)

    row.doubleClick()
    let field = live.element("session-row-rename-field", in: app)
    XCTAssertTrue(field.waitForExistence(timeout: 10), "a double-click began no rename")
    field.click()
    app.typeText("Abandoned")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(field.waitForNonExistence(timeout: 10), "Escape left the field open")
    live.assertRow("demo-question", in: app, contains: "Abandoned", false)
    live.assertRow("demo-question", in: app, contains: "Choose the first release")
  }

  /// Pin marks the row pinned and Unpin takes it back.
  @MainActor
  func testPinAndUnpin() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let row = live.row("demo-question", in: app)
    live.waitForDemoSessions(in: app)
    live.assertRow("demo-question", in: app, contains: "Pinned", false)

    live.contextMenu(row, choose: "Pin", in: app)
    live.assertRow("demo-question", in: app, contains: "Pinned")
    live.contextMenu(row, choose: "Unpin", in: app)
    live.assertRow("demo-question", in: app, contains: "Pinned", false)
  }

  /// Archive hides the row and offers Undo, which brings it back.
  @MainActor
  func testArchiveHidesASessionAndUndoRestoresIt() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let row = live.row("demo-question", in: app)

    live.contextMenu(row, choose: "Archive", in: app)
    XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the archived row stayed")
    live.click(live.element("undo-action", in: app), "Undo")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "Undo did not restore the session")
    XCTAssertTrue(
      live.element("undo-banner", in: app).waitForNonExistence(timeout: 10), "the banner stayed")
  }

  /// An archived session waits in the archived list, and Unarchive returns it to the main list.
  @MainActor
  func testArchivedSessionUnarchivesFromTheArchivedList() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let row = live.row("demo-question", in: app)

    live.contextMenu(row, choose: "Archive", in: app)
    XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the archived row stayed")
    live.click(live.element("undo-view-archived", in: app), "View archived")
    XCTAssertTrue(row.waitForExistence(timeout: 10), "the archived list does not show it")
    XCTAssertTrue(
      live.row("demo-design", in: app).waitForNonExistence(timeout: 10),
      "the archived list shows a live session")

    live.contextMenu(row, choose: "Unarchive", in: app)
    XCTAssertTrue(row.waitForNonExistence(timeout: 10), "it stayed in the archived list")
    live.showDisplayScope("All sessions", in: app)
    XCTAssertTrue(row.waitForExistence(timeout: 10), "it did not return to the main list")
  }

  /// Delete asks first: Cancel keeps the session and Delete removes it.
  @MainActor
  func testDeleteAsksFirst() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    let row = live.row("demo-question", in: app)

    live.contextMenu(row, choose: "Delete\u{2026}", in: app)
    live.clickDialogButton("Cancel", in: app)
    XCTAssertTrue(app.sheets.firstMatch.waitForNonExistence(timeout: 10), "the dialog stayed")
    XCTAssertTrue(row.exists, "Cancel deleted the session")

    live.contextMenu(row, choose: "Delete\u{2026}", in: app)
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(row.waitForNonExistence(timeout: 15), "Delete left the session")
  }

  /// Deleting the open session leaves its page rather than showing a dead transcript.
  @MainActor
  func testDeletingTheOpenSessionLeavesIt() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-question", in: app)

    live.contextMenu(live.row("demo-question", in: app), choose: "Delete\u{2026}", in: app)
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(
      live.element("transcript-demo-question", in: app).waitForNonExistence(timeout: 15),
      "the deleted session stayed on screen")
    live.assertRunning(app, "after deleting the open session")
  }
}
