import AppKit
import XCTest

/// The keys that scroll the table transcript in the app: once a message's text or the message
/// has the keyboard, the arrows scroll a line, and Page Up and Down, Space and Shift-Space a
/// page, out past the message itself.
///
/// They take the real mouse and keyboard; run them in a VM
/// (`vmq submit --flows MacTranscriptKeysFlowUITests`).
final class MacTranscriptKeysFlowUITests: XCTestCase {
  /// The table list, its messages drawn as TextKit text drawn ahead.
  private static let tableArguments = [
    "-omnigent:transcript-list", "table", "-omnigent:message-text", "textkit",
    "-omnigent:message-text-surface", "raster",
  ]

  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A click in an answer's text gives that text the keyboard; the keys scroll the transcript.
  @MainActor
  func testKeysScrollFromAMessagesText() throws {
    try assertKeysScroll { app, transcript in
      // Values are read only from text elements: a scroll bar's number never matches.
      let textTypes: [XCUIElement.ElementType] = [.staticText, .textView]
      let answers = app.descendants(matching: .any).matching(
        NSPredicate(
          format: "label BEGINSWITH %@ OR (elementType IN %@ AND value BEGINSWITH %@)",
          argumentArray: ["Done: step", textTypes.map(\.rawValue), "Done: step"]))
      let text = try XCTUnwrap(
        answers.allElementsBoundByIndex.first {
          $0.isHittable && $0.frame.intersects(Self.middle(of: transcript))
        }, "no answer's text in the middle of the transcript\n\(app.debugDescription)")
      text.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).click()
    }
  }

  /// With keyboard navigation on, a click in a message beside its text gives the message the
  /// keyboard, as a SwiftUI message made focusable does; the keys scroll the transcript.
  @MainActor
  func testKeysScrollFromAFocusedMessage() throws {
    try XCTSkipUnless(
      NSApplication.shared.isFullKeyboardAccessEnabled,
      "A message takes the keyboard on a click only with keyboard navigation on.")
    try assertKeysScroll { app, transcript in
      let rows = Self.messageRows(in: app)
      let row = try XCTUnwrap(
        rows.allElementsBoundByIndex.first {
          $0.isHittable && $0.frame.height > 60
            && $0.frame.intersects(Self.middle(of: transcript))
        }, "no message in the middle of the transcript")
      // Beside a question's bubble, which hugs the column's trailing edge.
      row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.3)).click()
    }
  }

  /// Opens the paged session over the table, has `focus` give the keyboard to something in its
  /// transcript, and checks each scrolling key moves the rows by a line or a page.
  @MainActor
  private func assertKeysScroll(
    focus: (XCUIApplication, CGRect) throws -> Void
  ) throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.pagedSession()
    let app = live.launch(arguments: Self.tableArguments)
    defer { app.terminate() }
    live.open(session, in: app)
    let scrollViews = app.scrollViews.matching(identifier: "transcript-\(session)")
    XCTAssertTrue(scrollViews.firstMatch.appears(within: 10), "no transcript to scroll")
    let transcript = try XCTUnwrap(
      scrollViews.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width }
    ).frame
    live.focusComposer(in: app)
    try focus(app, transcript)
    // From the end: up a page and a line, then back down the same way.
    let steps = [
      KeyStep(name: "Page Up", key: .pageUp, isPage: true, isUp: true),
      KeyStep(name: "Up", key: .upArrow, isPage: false, isUp: true),
      KeyStep(name: "Space", key: .space, isPage: true, isUp: false),
      KeyStep(name: "Shift-Space", key: .space, modifiers: .shift, isPage: true, isUp: true),
      KeyStep(name: "Down", key: .downArrow, isPage: false, isUp: false),
      KeyStep(name: "Page Down", key: .pageDown, isPage: true, isUp: false),
    ]
    for step in steps {
      let before = Self.rowTops(in: app, within: transcript)
      app.typeKey(step.key, modifierFlags: step.modifiers)
      let moved = try XCTUnwrap(
        Self.shift(since: before, in: app, within: transcript),
        "\(step.name): no row stayed in view")
      // The rows move down for a step up.
      let expected: ClosedRange<CGFloat> = step.isPage ? 200...2000 : 30...50
      XCTAssertTrue(
        expected.contains(step.isUp ? moved : -moved), "\(step.name) moved the rows \(moved)")
    }
    live.assertRunning(app, "after scrolling by keys")
  }

  /// A key that scrolls a line or a page, up or down.
  private struct KeyStep {
    var name: String
    var key: XCUIKeyboardKey
    var modifiers: XCUIElement.KeyModifierFlags = []
    var isPage: Bool
    var isUp: Bool
  }

  /// The transcript's middle third, where the clicked message is.
  private static func middle(of transcript: CGRect) -> CGRect {
    transcript.insetBy(dx: 0, dy: transcript.height / 3)
  }

  /// The messages' rows, by identifier.
  @MainActor
  private static func messageRows(in app: XCUIApplication) -> XCUIElementQuery {
    app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'message-' AND NOT identifier BEGINSWITH 'message-text-'"))
  }

  /// Each message row's top in view, by identifier, once the transcript has had a moment to
  /// move. A row that left between the query and the read is skipped.
  @MainActor
  private static func rowTops(in app: XCUIApplication, within transcript: CGRect)
    -> [String: CGFloat]
  {
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    var tops: [String: CGFloat] = [:]
    for row in messageRows(in: app).allElementsBoundByIndex where row.exists {
      let frame = row.frame
      if frame.intersects(transcript) { tops[row.identifier] = frame.minY }
    }
    return tops
  }

  /// How far the rows moved since `before`: the middle of the moves of the rows in view at both
  /// times; `nil` when none was.
  @MainActor
  private static func shift(
    since before: [String: CGFloat], in app: XCUIApplication, within transcript: CGRect
  ) -> CGFloat? {
    let after = rowTops(in: app, within: transcript)
    let moves = before.compactMap { id, top in after[id].map { $0 - top } }.sorted()
    return moves.isEmpty ? nil : moves[moves.count / 2]
  }
}
