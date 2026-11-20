import AppKit
import XCTest

/// Typing in a session's composer on the offline demo server.
extension MacComposerFlowUITests {
  /// Typing on after a tinted command keeps the app up and the draft whole: the editor's draft
  /// write once ran inside the text view's storage commit and trapped there. Hosted windows never
  /// trap on that editor, and neither did this flow in a VM; it guards the real typing path.
  @MainActor
  func testTypingOnAfterATintedCommandKeepsTheDraft() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)
    live.focusComposer(in: app)
    let draft = "/context @x more text, typed on after the command"
    app.typeText(draft)
    live.assertRunning(app, "typing after the command")
    app.typeText(" and on")
    live.assertRunning(app, "typing on")
    XCTAssertTrue(
      live.waitUntil(timeout: 10) { live.composerText(in: app) == draft + " and on" },
      "the composer holds \(live.composerText(in: app))")
  }
}
