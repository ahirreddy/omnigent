import XCTest

/// A PDF and a video in the fixture session's workspace, as the web's file viewer shows them:
/// `notes.pdf`, and `media/demo.mp4` with its chapters, which `Tools/seed-ui-test-fixtures.py`
/// writes.
final class MacWorkspaceMediaFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A PDF opens in PDFKit with its page count, as the web's PDF viewer shows it.
  @MainActor
  func testAPDFOpensInPDFKit() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")

    live.click(live.element("workspace.tree.row.notes.pdf", in: app), "notes.pdf", timeout: 30)
    XCTAssertTrue(live.element("workspace.pdf", in: app).appears(within: 20), "no PDF pages")
    XCTAssertTrue(
      live.text(containing: "1 page", in: app).appears(within: 10), "no page count")
    XCTAssertFalse(live.element("workspace.pdf.note", in: app).exists, "the PDF did not open")
    live.shot(app, "workspace-pdf")
  }

  /// A video waits for Play, then streams into the system player through ranged downloads, with
  /// its recording's chapters beside it.
  @MainActor
  func testAVideoPlaysFromTheWorkspace() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let workspace = try live.fixtureWorkspace()
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: workspace.appending(path: "media/demo.mp4").path),
      "The fixture workspace has no media/demo.mp4 (the seeder records it with `say`).")
    let app = live.launch()
    defer { app.terminate() }
    live.open(session, in: app)
    live.showInspector(in: app)
    live.click(live.element("inspector-tab-files", in: app), "the Files tab")

    live.click(live.element("workspace.tree.row.media", in: app), "the media folder", timeout: 30)
    live.click(
      live.element("workspace.tree.row.media/demo.mp4", in: app), "demo.mp4", timeout: 20)
    let play = live.element("workspace.video.play", in: app)
    XCTAssertTrue(play.appears(within: 20), "no Play recording")
    XCTAssertTrue(
      live.text(containing: "Say goodbye", in: app).appears(within: 20), "no chapters")
    play.click()
    XCTAssertTrue(
      live.element("workspace.video.player", in: app).appears(within: 20), "no player")
    XCTAssertTrue(
      live.element("workspace.video.loading", in: app).disappears(within: 30),
      "the video never became ready to play")
    XCTAssertFalse(
      live.element("workspace.video.failure", in: app).exists, "the video failed to play")
    live.shot(app, "workspace-video")
  }
}
