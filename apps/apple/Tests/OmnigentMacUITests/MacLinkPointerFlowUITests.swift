import AppKit
import XCTest

/// The pointer over a link in a message: a hand in the chat and in the terminal view, and no hand
/// on the words beside the link or off the message. The cursor read is the system's, so the
/// pointer has to be real.
///
/// They take the real mouse; run them in a VM (`vm-test.sh MacLinkPointerFlowUITests`).
final class MacLinkPointerFlowUITests: XCTestCase {
  private static let address = "https://example.com/guide"

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A link in a chat message, which the rich markdown draws.
  @MainActor
  func testAChatLinkTurnsThePointerIntoAHand() {
    assertHandOverALink(arguments: [])
  }

  /// A link in a terminal-view message, which the plain source text draws.
  @MainActor
  func testATerminalViewLinkTurnsThePointerIntoAHand() {
    assertHandOverALink(arguments: ["-omnigent:transcript-style", "cli"])
  }

  /// Sends a message that starts with a link and moves the pointer over the link, the words
  /// after it, the link again, the composer and back to the words.
  @MainActor
  private func assertHandOverALink(arguments: [String]) {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo(arguments: arguments)
    defer { app.terminate() }
    let words = "pointer check \(UUID().uuidString.prefix(6)) with some more plain words"
    live.startDemoSession("\(Self.address) \(words)", in: app)
    XCTAssertTrue(
      live.element("composer-stop", in: app).disappears(within: 30), "the reply never ended")

    // The message's text holds its link as an element of its own, the size of the link.
    let linked = app.links.matching(NSPredicate(format: "title == %@", Self.address)).firstMatch
    XCTAssertTrue(
      linked.appears(within: 15), "the message's link is not there\n\(app.debugDescription)")
    let link = linked.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let plainWords = linked.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
      .withOffset(CGVector(dx: 40, dy: 0))

    link.hover()
    assertCursor(isHand: true, "over the link", live)
    plainWords.hover()
    assertCursor(isHand: false, "over the words after the link", live)
    link.hover()
    assertCursor(isHand: true, "over the link again", live)
    live.composer(in: app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
    assertCursor(isHand: false, "over the composer", live)
    plainWords.hover()
    assertCursor(isHand: false, "back over the words", live)
    live.assertRunning(app, "after pointing at a link")
  }

  /// Whether the system's cursor is the pointing hand. The test runner reads the hand's image;
  /// the arrow's and the I-beam's come back empty in it, so those two can't be told apart here.
  @MainActor
  private static var isHand: Bool {
    let current = NSCursor.currentSystem?.image.tiffRepresentation
    return current == NSCursor.pointingHand.image.tiffRepresentation
  }

  /// Waits for the hand to show or go, then checks that it stays so once the pointer rests: the
  /// row's hover reveal settles after the pointer stops.
  @MainActor
  private func assertCursor(
    isHand expected: Bool, _ place: String, _ live: MacLiveUITestSupport,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let expectation = expected ? "the hand" : "no hand"
    XCTAssertTrue(
      live.waitUntil(timeout: 5) { Self.isHand == expected },
      "\(place) there is \(expected ? "no hand" : "the hand")", file: file, line: line)
    let rested = live.waitUntil(timeout: 1.5) { Self.isHand != expected }
    XCTAssertFalse(
      rested, "\(place) \(expectation) did not last while the pointer rested",
      file: file, line: line)
  }
}
