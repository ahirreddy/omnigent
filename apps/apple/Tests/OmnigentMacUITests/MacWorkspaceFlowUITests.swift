import XCTest

/// A session's files and right panel on the local server's fixture session, whose workspace is
/// seeded with README.md, docs/, src/ and notes.
final class MacWorkspaceFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// One click on a file in the tree opens it in the viewer.
  @MainActor
  func testSingleClickOpensAFile() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")

    live.click(live.element("workspace.tree.row.README.md", in: app), "README.md", timeout: 30)
    XCTAssertTrue(
      live.element("workspace.viewer", in: app).waitForExistence(timeout: 20),
      "one click did not open the file")
  }

  /// The Changes tab lists the session's changes, or says there are none.
  @MainActor
  func testChangesTabShowsTheChangesList() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)

    live.click(live.element("inspector-tab-changes", in: app), "the Changes tab")
    XCTAssertTrue(
      live.element("workspace.changes", in: app).waitForExistence(timeout: 20), "no changes list")
  }

  /// Every section the right panel offers shows its own content.
  @MainActor
  func testInspectorShowsEverySection() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)

    let sections = [
      ("files", live.element("workspace.tree", in: app)),
      ("changes", live.element("workspace.changes", in: app)),
      ("search", live.element("workspace.search", in: app)),
      ("info", live.text(containing: "Session ID", in: app)),
    ]
    for (section, content) in sections {
      live.click(live.element("inspector-tab-\(section)", in: app), "the \(section) tab")
      XCTAssertTrue(content.waitForExistence(timeout: 20), "the \(section) section shows nothing")
    }
    for section in ["pullRequests", "agents"] {
      let tab = live.element("inspector-tab-\(section)", in: app)
      if tab.exists { tab.click() }
      live.assertRunning(app, "on the \(section) section")
    }
  }

  /// The tree's filter narrows the files to the matching ones.
  @MainActor
  func testFileFilterNarrowsTheTree() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")
    let notes = live.element("workspace.tree.row.notes.md", in: app)
    XCTAssertTrue(notes.waitForExistence(timeout: 30), "the tree did not load")

    let filter = live.element("workspace.tree.filter", in: app)
    live.click(filter, "the filter")
    filter.typeText("README")
    XCTAssertTrue(notes.waitForNonExistence(timeout: 15), "the filter left a file that differs")
    XCTAssertTrue(live.element("workspace.tree.row.README.md", in: app).exists, "it hid the match")
  }

  /// Typing @ offers the workspace's files, and attaching a folder puts it in the composer.
  @MainActor
  func testAtMentionAttachesAFolder() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    live.click(live.composer(in: app), "the composer")
    app.typeText("@")
    XCTAssertTrue(
      live.element("composer-completions", in: app).waitForExistence(timeout: 20), "no completions")
    live.click(live.element("composer-completion-@src/", in: app), "the src folder", timeout: 20)
    live.click(
      live.element("composer-completion-attach-@src/model/", in: app), "Attach model", timeout: 20)
    XCTAssertTrue(
      live.element("composer-mention-src/model/", in: app).waitForExistence(timeout: 10),
      "the folder is not in the composer")
    // Leave the fixture's draft as it was for the next flow.
    app.typeKey("a", modifierFlags: .command)
    app.typeKey(.delete, modifierFlags: [])
  }

  /// Fork copies the conversation into a new session and opens it; deleting cleans up.
  @MainActor
  func testForkCopiesTheConversationIntoANewSession() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)

    live.contextMenu(live.row(session, in: app), choose: "Fork", in: app)
    XCTAssertTrue(live.element("fork-sheet", in: app).waitForExistence(timeout: 15), "no sheet")
    live.click(live.element("fork-clone", in: app), "Fork")

    let original = live.element("transcript-\(session)", in: app)
    XCTAssertTrue(original.waitForNonExistence(timeout: 30), "the fork did not open")
    let fork = live.anyTranscript(in: app)
    XCTAssertTrue(fork.waitForExistence(timeout: 30), "no transcript for the fork")
    XCTAssertTrue(
      live.text(containing: "List the workspace and summarize it.", in: app)
        .waitForExistence(timeout: 30),
      "the fork does not have the conversation")

    let forkID = fork.identifier.replacing("transcript-", with: "")
    live.contextMenu(live.row(forkID, in: app), choose: "Delete\u{2026}", in: app)
    live.clickDialogButton("Delete", in: app)
    XCTAssertTrue(live.row(forkID, in: app).waitForNonExistence(timeout: 15), "the fork stayed")
  }
}
