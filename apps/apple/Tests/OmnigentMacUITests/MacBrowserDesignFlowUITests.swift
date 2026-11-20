import AppKit
import XCTest

/// Annotate and Draw on a browser tab's page, end to end on a live local server: the toolbar
/// opens the tool, the page's element is picked and described, and the request with its
/// screenshot reaches the session.
final class MacBrowserDesignFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  #if OMNIGENT_CHROMIUM
    /// A page whose heading fills its top, so a click there picks it.
    private func writeDesignPage() throws -> (url: URL, title: String) {
      let folder = MacLiveUITestSupport.scratchDirectory()
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let title = "Design check \(UUID().uuidString.prefix(8))"
      let url = folder.appending(path: "design.html")
      let html = """
        <!doctype html><title>\(title)</title><body style="margin:0">
        <h1 id=banner style="margin:0;height:240px;background:#eef">\(title)</h1>
        <p>Below the banner.</p></body>
        """
      try html.write(to: url, atomically: true, encoding: .utf8)
      return (url, title)
    }

    /// Annotate: pick the heading, say what should change, send; the page says it was sent and
    /// the session's chat shows the request as a design card.
    @MainActor
    func testAnnotateSendsThePickedElementToTheSession() throws {
      let live = MacLiveUITestSupport(self)
      let session = try live.fixtureSession()
      let page = try writeDesignPage()
      let app = live.launch()
      defer { app.terminate() }
      live.open(session, in: app)
      live.openBrowserTab(loading: page, in: app)
      MacNotificationPrompts.decline(waiting: 2)

      live.click(live.element("browser.design.annotate", in: app), "the Annotate button")
      let layer = live.element("browser.design.annotateLayer", in: app)
      XCTAssertTrue(layer.appears(within: 10), "Annotate's layer never showed")
      layer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).click()
      let request = live.element("browser.design.request", in: app)
      XCTAssertTrue(request.appears(within: 10), "picking the heading opened no request card")
      request.click()
      app.typeText("Make the banner taller")
      live.click(live.element("browser.design.send", in: app), "Send to Agent")
      XCTAssertTrue(
        live.text(containing: "Sent to agent", in: app).appears(within: 30),
        "the request was never sent\n\(app.debugDescription)")
      live.assertRunning(app, "after sending the request")

      // The chat shows it as the design card: its words over the picked element.
      live.tabs("chat", in: app).firstMatch.click()
      XCTAssertTrue(
        live.text(containing: "Make the banner taller", in: app).appears(within: 30),
        "the session's chat never showed the request")
      XCTAssertTrue(live.text(containing: "h1#banner", in: app).appears(within: 10))
    }

    /// Draw: a stroke over the page and a note; Escape leaves the tool without sending.
    @MainActor
    func testDrawMarksThePageAndEscapeLeaves() throws {
      let live = MacLiveUITestSupport(self)
      let session = try live.fixtureSession()
      let page = try writeDesignPage()
      let app = live.launch()
      defer { app.terminate() }
      live.open(session, in: app)
      live.openBrowserTab(loading: page, in: app)
      MacNotificationPrompts.decline(waiting: 2)

      live.click(live.element("browser.design.draw", in: app), "the Draw button")
      let layer = live.element("browser.design.drawLayer", in: app)
      XCTAssertTrue(layer.appears(within: 10), "Draw's layer never showed")
      let send = live.element("browser.design.send", in: app)
      XCTAssertFalse(send.isEnabled, "Send was on before anything was drawn")
      let start = layer.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
      start.press(
        forDuration: 0.1,
        thenDragTo: layer.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.7)))
      XCTAssertTrue(live.waitUntil { send.isEnabled }, "the stroke didn't count as a mark")
      app.typeKey(.escape, modifierFlags: [])
      XCTAssertTrue(layer.disappears(within: 10), "Escape left Draw open")
      live.assertRunning(app, "after leaving Draw")
    }
  #endif
}
