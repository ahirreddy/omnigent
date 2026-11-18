import AppKit
import XCTest

/// Runtime text in a transcript on the offline demo server: a message that reads as a
/// `[System: …]` notice shows as the web's muted marker, never as the person's bubble.
final class MacTranscriptMarkerFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A sent `[System: timer … fired]` echoes as "System: Timer … fired" and leaves no bubble.
  @MainActor
  func testRuntimeNoticeShowsAsAMarker() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.startIdleDemoSession(in: app)

    let timer = "t\(UUID().uuidString.prefix(6).lowercased())"
    let raw = "[System: timer \(timer) fired]"
    live.send(raw, in: app)
    XCTAssertTrue(
      live.text(containing: "System: Timer \(timer) fired", in: app).appears(within: 20),
      "the notice did not show as a marker")
    let bubbles = live.elements(prefix: "message-", in: app)
    let rawText = bubbles.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", argumentArray: [raw, raw]))
    XCTAssertTrue(
      live.waitUntil(timeout: 10) { !rawText.firstMatch.exists },
      "the notice's raw text still shows in a message bubble")
  }
}
