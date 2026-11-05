import XCTest

/// The fixture session's workspace on touch (see `LiveServerUITestSupport`): an `@` mention
/// browses into a folder and attaches one whole, and a file opens in Edit and saves.
final class WorkspaceUITests: XCTestCase {
  @MainActor
  func testMentionBrowsesAFolderAndAttachesOne() throws {
    let support = LiveServerUITestSupport(self)
    let sessionID = try support.fixtureSession()
    let app = support.launch(opening: sessionID)
    support.waitForTranscript(sessionID, in: app)
    let input = app.textViews["composer-input"]
    support.tap(input, "the composer")
    support.type("@", into: input)

    let header = support.element("composer-completion-folder", in: app)
    XCTAssertTrue(header.waitForExistence(timeout: 10), "@ listed no workspace")
    support.tap(support.element("composer-completion-@src/", in: app), "the src folder")
    XCTAssertTrue(support.waitUntil { header.label == "/src" }, "src did not open: \(header.label)")
    support.shot("mention-src")
    support.tap(support.element("composer-completion-attach-@src/model/", in: app), "Attach model")
    XCTAssertTrue(
      support.element("composer-mention-src/model/", in: app).waitForExistence(timeout: 5),
      "Attach did not add the folder chip")
    XCTAssertFalse(header.exists, "the completions stayed open after attaching")
    support.shot("mention-attached")
  }

  @MainActor
  func testFileOpensInEditAndSaves() throws {
    let support = LiveServerUITestSupport(self)
    let sessionID = try support.fixtureSession()
    let app = support.launch(opening: sessionID)
    support.waitForTranscript(sessionID, in: app)
    support.tap(app.buttons["toggle-inspector"], "the right-panel toggle")
    // The tree's rows are buttons; a tap opens a folder or file.
    support.tap(support.element("src", in: app), "the src folder", timeout: 15)
    support.tap(support.element("main.swift", in: app), "main.swift")
    support.tap(
      support.element("workspace.viewer.mode", in: app).buttons["Edit"], "the Edit mode")
    let editor = support.element("workspace.editor", in: app)
    support.tap(editor, "the editor")
    support.type("// edited by the UI test\n", into: editor)
    let save = app.buttons["workspace.editor.save"]
    XCTAssertTrue(support.waitUntil { save.isEnabled }, "the edit left Save off")
    support.shot("file-edit-unsaved")
    save.tap()
    XCTAssertTrue(
      app.staticTexts["Saved"].waitForExistence(timeout: 10) || !save.isEnabled,
      "Save did not save")
    if let workspace = ProcessInfo.processInfo.environment["OMNIGENT_UITEST_WORKSPACE"] {
      let saved = try String(
        contentsOfFile: "\(workspace)/src/main.swift", encoding: .utf8)
      XCTAssertTrue(saved.contains("edited by the UI test"), "the file on disk is \(saved)")
    }
    support.shot("file-edit-saved")
  }
}
