import UIKit
import XCTest

/// Editing and commenting on a workspace file on iPhone and iPad against a live server: the
/// edit saves, a selection gets a comment, and the comment resolves to Sent.
///
/// Skipped unless the runner gets `OMNIGENT_E2E_SERVER_URL` and `OMNIGENT_EDIT_SESSION_ID` (a
/// session whose workspace has `main.rs`), with the `TEST_RUNNER_` prefix. The test edits
/// `main.rs` and leaves a resolved comment. Set `TEST_RUNNER_FILES_SHOTS_DIR` to also write
/// each state as `<device>-<state>.png` there.
final class FileCommentsUITests: XCTestCase {
  private var environment: [String: String] { ProcessInfo.processInfo.environment }
  private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }

  @MainActor
  func testEditSaveCommentAndResolve() throws {
    let app = try launch()
    try open(try setting("OMNIGENT_EDIT_SESSION_ID"), in: app)
    let file = app.buttons["main.rs"].firstMatch
    // The iPad may restore the right panel open; the toggle would then close it.
    if !file.waitForExistence(timeout: 5) {
      tap(app.buttons["toggle-inspector"], "the right-panel toggle")
    }
    XCTAssertTrue(file.waitForExistence(timeout: 20), "the files panel shows no main.rs")
    file.doubleTap()
    XCTAssertTrue(app.descendants(matching: .any)["workspace.viewer"].waitForExistence(timeout: 15))
    // The phone's panel is a half-height sheet: give the editor and keyboard the screen.
    let grabber = app.buttons["Sheet Grabber"]
    if isPhone, grabber.exists {
      grabber.press(forDuration: 0.1, thenDragTo: app.navigationBars.firstMatch)
    }
    tap(app.segmentedControls.buttons["Edit"].firstMatch, "Edit")

    // Type at the end of the file, then save.
    let editor = app.textViews["workspace.editor"]
    XCTAssertTrue(editor.waitForExistence(timeout: 10), "the editor did not open")
    editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
    let marker = "// edited on \(isPhone ? "iPhone" : "iPad")"
    editor.typeText("\(marker)\n")
    try shot("edit-unsaved")
    let save = app.buttons["workspace.editor.save"]
    if save.isEnabled { save.tap() }
    XCTAssertTrue(waitUntil { !save.isEnabled }, "Save stays on after saving")
    XCTAssertTrue((editor.value as? String ?? "").contains(marker))
    try shot("edit-saved")

    // Comment on a word of the saved text.
    let commentButton = app.buttons["workspace.review.comment"]
    let firstWord = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.02))
    for _ in 0..<3 where !commentButton.exists {
      firstWord.tap()
      firstWord.doubleTap()
      _ = commentButton.waitForExistence(timeout: 3)
    }
    tap(commentButton, "Comment on the selection")
    let field = app.descendants(matching: .any)["workspace.review.commentText"]
    tap(field, "the comment field")
    field.typeText("Rename this from the simulator")
    tap(app.buttons["workspace.review.commentSend"], "Add Comment")
    try showComments(in: app)
    let body = app.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "Rename this from the simulator")
    ).firstMatch
    XCTAssertTrue(body.waitForExistence(timeout: 10), "the new comment is not listed")
    try shot("comment-open")

    tap(app.buttons["workspace.comment.resolve"].firstMatch, "Resolve")
    XCTAssertTrue(waitUntil { !body.exists }, "the resolved comment stays under Open")
    let tabs = app.segmentedControls["workspace.comments.tabs"]
    tap(tabs.buttons.element(boundBy: 1), "the Sent tab")
    XCTAssertTrue(body.waitForExistence(timeout: 10), "the resolved comment is not under Sent")
    XCTAssertTrue(app.buttons["workspace.comment.reopen"].firstMatch.exists)
    try shot("comment-sent")
  }

  // MARK: Helpers

  @MainActor
  private func showComments(in app: XCUIApplication) throws {
    let panel = app.descendants(matching: .any)["workspace.comments"]
    if panel.waitForExistence(timeout: 3) { return }
    tap(app.descendants(matching: .any)["workspace.review.comments"], "the Comments toggle")
    XCTAssertTrue(panel.waitForExistence(timeout: 10), "the comments panel did not open")
  }

  @MainActor
  private func waitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if condition() { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    return condition()
  }

  @MainActor
  private func setting(_ name: String) throws -> String {
    guard let value = environment[name] else {
      throw XCTSkip("Set TEST_RUNNER_\(name) to run.")
    }
    return value
  }

  /// The app connected to the live server, with no restored tabs.
  @MainActor
  private func launch() throws -> XCUIApplication {
    let server = try setting("OMNIGENT_E2E_SERVER_URL")
    let app = XCUIApplication()
    app.launchArguments += ["-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES"]
    app.launch()
    XCUIDevice.shared.orientation = isPhone ? .portrait : .landscapeLeft
    return app
  }

  /// Opens a session from the sidebar, going back until its row shows.
  @MainActor
  private func open(_ sessionID: String, in app: XCUIApplication) throws {
    let row = app.descendants(matching: .any)["session-row-\(sessionID)"]
    for _ in 0..<3 where !row.waitForExistence(timeout: 8) {
      let back = app.navigationBars.buttons["BackButton"]
      guard back.exists else { break }
      back.tap()
    }
    XCTAssertTrue(row.exists, "no row for \(sessionID)")
    row.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.15)).tap()
    sleep(2)
  }

  @MainActor
  private func tap(_ element: XCUIElement, _ name: String) {
    XCTAssertTrue(element.waitForExistence(timeout: 10), "\(name) is missing")
    element.tap()
  }

  @MainActor
  private func shot(_ state: String) throws {
    let screenshot = XCUIScreen.main.screenshot()
    let device = isPhone ? "iphone" : "ipad"
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = "\(device)-\(state)"
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let directory = environment["FILES_SHOTS_DIR"] else { return }
    try screenshot.pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("\(device)-\(state).png"))
  }
}
