import XCTest

/// The panels macOS itself draws over the app, on the offline demo server: the save panel an
/// export goes through, the print sheet of a browser page and the photo picker.
final class MacSystemPanelFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// The session menu's Export… asks where to save, and writes the transcript there: the
  /// session's own line first, then a line per item.
  @MainActor
  func testExportSavesTheTranscript() throws {
    let live = MacLiveUITestSupport(self)
    let folder = MacLiveUITestSupport.scratchDirectory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let saved = folder.appending(path: "demo-notes.jsonl")
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)

    live.openSessionMenu(in: app)
    live.clickMenuItem("Export", in: app)
    // The save panel: Go to Folder, the folder's path, then Export under the offered name.
    let panel = app.sheets.firstMatch
    XCTAssertTrue(panel.appears(within: 15), "no save panel\n\(app.debugDescription)")
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(folder.path + "\r")
    live.clickDialogButton("Export", in: app)

    XCTAssertTrue(
      live.waitUntil(timeout: 15) { FileManager.default.fileExists(atPath: saved.path) },
      "nothing was saved as \(saved.lastPathComponent)")
    XCTAssertTrue(panel.disappears(within: 10), "the save panel stayed")
    let lines = try String(contentsOf: saved, encoding: .utf8).split(separator: "\n")
    let first = try XCTUnwrap(lines.first, "the saved transcript is empty")
    XCTAssertTrue(
      first.contains("session_meta") && first.contains("demo-notes"),
      "the transcript does not start with its session: \(first)")
    XCTAssertGreaterThan(lines.count, 1, "the transcript has no items")
    live.assertRunning(app, "after the export")
  }

  #if OMNIGENT_CHROMIUM
    /// Print… in a browser tab's menu shows the system print sheet for the page (Chromium, the
    /// default engine, renders it to a PDF first), and Cancel returns to the page.
    @MainActor
    func testPrintShowsThePrintSheet() throws {
      try printShowsThePrintSheet(engineArguments: [])
    }

    /// The same with the system's engine, WebKit, which prints the page's own view.
    @MainActor
    func testPrintShowsThePrintSheetOnWebKit() throws {
      try printShowsThePrintSheet(engineArguments: ["-ai.omnigent.browser.engine", "system"])
    }

    /// Loads a page in a browser tab, chooses Print… and cancels the sheet.
    /// - Parameter engineArguments: Launch arguments choosing the engine, for this launch only.
    /// - Throws: When the page to print cannot be written.
    @MainActor
    private func printShowsThePrintSheet(engineArguments: [String]) throws {
      let live = MacLiveUITestSupport(self)
      let page = try live.writePage(title: "Omnigent print check \(UUID().uuidString.prefix(8))")
      let app = live.launchDemo(arguments: engineArguments)
      defer { app.terminate() }
      live.openDemo("demo-question", in: app)
      live.openBrowserTab(loading: page, in: app)

      live.click(live.element("browser.tabMenu", in: app), "the tab's menu")
      live.clickMenuItem("Print", in: app)
      let sheet = app.sheets.firstMatch
      XCTAssertTrue(sheet.appears(within: 30), "no print sheet\n\(app.debugDescription)")
      XCTAssertTrue(
        sheet.buttons["Print"].appears(within: 10),
        "the sheet has no Print button\n\(app.debugDescription)")
      declineLocalNetworkPrompt()
      live.clickDialogButton("Cancel", in: app)
      XCTAssertTrue(sheet.disappears(within: 15), "Cancel left the print sheet")
      XCTAssertTrue(live.text(containing: page.title, in: app).exists, "the page is gone")
      live.assertRunning(app, "after cancelling the print sheet")
    }

    /// Whether a print sheet of this run already showed the local network prompt is answered.
    @MainActor private static var localNetworkIsAnswered = false

    /// Answers the system's "find devices on local networks" prompt with Don't Allow. The app's
    /// first print sheet on a machine raises it mid-screen, a few seconds after the sheet (it
    /// looks for printers), and it stays over every later flow until it is answered.
    @MainActor
    private func declineLocalNetworkPrompt() {
      let system = XCUIApplication(bundleIdentifier: "com.apple.UserNotificationCenter")
      let prompt = system.staticTexts.matching(
        NSPredicate(format: "value CONTAINS %@", "local networks")
      ).firstMatch
      let wait: TimeInterval = Self.localNetworkIsAnswered ? 0 : 8
      Self.localNetworkIsAnswered = true
      guard prompt.appears(within: wait) else { return }
      let decline = system.dialogs.buttons.matching(
        NSPredicate(format: "title BEGINSWITH %@", "Don")
      ).firstMatch
      XCTAssertTrue(decline.exists, "the prompt has no Don't Allow\n\(system.debugDescription)")
      decline.click()
      XCTAssertTrue(prompt.disappears(within: 10), "the local network prompt stayed")
    }
  #endif

  /// The Add menu's Photos… shows the system photo picker, and the photo chosen there attaches.
  /// The picker draws in another process and gives UI automation no elements, so it is clicked
  /// by position: the Recently Saved album, its first photo, then Add.
  @MainActor
  func testPhotosPickerAttachesAPhoto() throws {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    live.click(live.element("composer-add", in: app), "the Add menu")
    live.clickMenuItem("Photos", in: app)
    let picker = app.sheets.firstMatch
    XCTAssertTrue(picker.appears(within: 15), "no photo picker\n\(app.debugDescription)")
    // The picker fills in after it shows, and a click before then is lost: choose again.
    for _ in 0..<4 where picker.exists {
      let corner = picker.coordinate(withNormalizedOffset: .zero)
      corner.withOffset(CGVector(dx: 96, dy: 224)).click()
      corner.withOffset(CGVector(dx: 254, dy: 130)).click()
      pickerButton(picker, fromTrailingEdge: 50).click()
      _ = picker.disappears(within: 6)
    }
    guard !picker.exists else {
      pickerButton(picker, fromTrailingEdge: 140).click()
      XCTAssertTrue(picker.disappears(within: 10), "Cancel left the photo picker")
      throw XCTSkip(
        "The picker opened and closed, and no more: Add stayed off, so this machine's photo "
          + "library has nothing in Recently Saved. Import one image with Photos.")
    }

    XCTAssertTrue(
      live.elements(prefix: "draft-attachment-", in: app).firstMatch.appears(within: 15),
      "the chosen photo is not attached")
    live.assertRunning(app, "after choosing a photo")
  }

  /// A button of the picker's bottom bar, by how far its middle is from the trailing edge.
  @MainActor
  private func pickerButton(_ picker: XCUIElement, fromTrailingEdge distance: CGFloat)
    -> XCUICoordinate
  {
    picker.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -distance, dy: -28))
  }
}
