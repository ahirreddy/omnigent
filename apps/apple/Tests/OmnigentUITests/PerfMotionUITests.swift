import CryptoKit
import UIKit
import XCTest
import notify

/// Motion with a long transcript open against the local server's large seed (`just
/// apple-seed-large`), for frame measurements (docs/performance.md): rotating the device,
/// showing and hiding the keyboard, and on iPad hiding the sidebar, rotating and dragging the
/// split view's divider. Each step is one interval of the Debug frame monitor
/// (`ai.omnigent.perf.begin` / `.end`): `log stream --predicate 'subsystem == "ai.omnigent.perf"'`
/// shows one stats line per step, in the order of the test's activities. After each step the
/// transcript must still show rows (a screenshot is attached).
///
/// `TEST_RUNNER_OMNIGENT_STYLE` picks the transcript style (chat or cli) and
/// `TEST_RUNNER_OMNIGENT_LONG` the long transcript (0-2); without it or a seeded run, it skips.
final class PerfMotionUITests: XCTestCase {
  private var server: String {
    ProcessInfo.processInfo.environment["OMNIGENT_SERVER"] ?? "http://127.0.0.1:6767"
  }

  private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

  @MainActor
  func testRotateWithLongTranscript() throws {
    let app = try launch()
    // The app's perf driver rotates the scene: `XCUIDevice` orientation changes do not reach
    // the iPhone simulator's app here.
    for direction in ["landscape", "portrait", "landscape", "portrait"] {
      measureStep("rotate to \(direction)") { unsafe notify_post("ai.omnigent.perf.rotate") }
    }
    XCTAssertTrue(transcript(app).exists, "the transcript went away")
  }

  @MainActor
  func testKeyboardWithLongTranscript() throws {
    let app = try launch()
    let input = app.textViews["composer-input"]
    XCTAssertTrue(input.waitForExistence(timeout: 10), "no composer")
    for _ in 0..<2 {
      measureStep("keyboard show") {
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "no keyboard")
      }
      // With a hardware keyboard the on-screen one has no height: nothing to drag it away.
      guard app.keyboards.firstMatch.frame.height > 0 else {
        throw XCTSkip("the simulator shows no on-screen keyboard (hardware keyboard connected)")
      }
      measureStep("keyboard hide") {
        // The transcript dismisses the keyboard interactively: drag from it into the keyboard.
        let start = transcript(app).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let keyboard = app.keyboards.firstMatch
        start.press(
          forDuration: 0.05,
          thenDragTo: keyboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "kept keyboard")
      }
    }
  }

  @MainActor
  func testPadSplitWithLongTranscripts() throws {
    guard isPad else { throw XCTSkip("iPad layout only") }
    let app = try launch()
    try openURL("omnigent://\(serverHost)/c/\(Self.longSession((longIndex + 1) % 3))")
    let tab = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH 'tab-chat-'")).element(boundBy: 0)
    XCTAssertTrue(tab.waitForExistence(timeout: 20), "no chat tab in the strip")
    let divider = app.descendants(matching: .any)["tab-split-divider"].firstMatch
    // Restored tabs may already be split.
    if !divider.waitForExistence(timeout: 3) {
      tab.press(forDuration: 1.2)
      let split = app.buttons["tab-menu-split"]
      XCTAssertTrue(split.waitForExistence(timeout: 5), "no Open in Split View")
      split.tap()
    }
    XCTAssertTrue(divider.waitForExistence(timeout: 10), "the split did not open")
    sleep(3)
    for offset in [-0.15, 0.15] {
      measureStep("drag the split divider") {
        let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let window = app.windows.firstMatch
        let end = start.withOffset(CGVector(dx: window.frame.width * offset, dy: 0))
        start.press(forDuration: 0.2, thenDragTo: end)
      }
    }
    measureStep("rotate to portrait") { XCUIDevice.shared.orientation = .portrait }
    measureStep("rotate to landscape") { XCUIDevice.shared.orientation = .landscapeLeft }
    XCTAssertTrue(divider.exists, "the split went away")
  }

  @MainActor
  func testPadSidebarWithLongTranscript() throws {
    guard isPad else { throw XCTSkip("iPad layout only") }
    let app = try launch()
    let toggle = app.navigationBars.buttons["ToggleSidebar"].firstMatch
    guard toggle.waitForExistence(timeout: 5) else {
      throw XCTSkip("no sidebar button in this layout")
    }
    for _ in 0..<2 {
      measureStep("sidebar toggle") { toggle.tap() }
    }
  }

  /// Rotating keeps a transcript at the bottom there, and one scrolled up on the same heading.
  @MainActor
  func testPadRotationKeepsReadingPosition() throws {
    guard isPad else { throw XCTSkip("iPad layout only") }
    let app = try launch()
    let jump = app.buttons["jump-to-latest"]
    if jump.exists {
      jump.tap()
      sleep(2)
    }
    XCTAssertTrue(isAtBottom(app), "not at the bottom before rotating")
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      measureStep("rotate at the bottom") { XCUIDevice.shared.orientation = orientation }
      XCTAssertTrue(isAtBottom(app), "left the bottom rotating to \(orientation.rawValue)")
    }
    // Past the mock model's identical replies into the seeded turns, whose headings are unique.
    var heading: String?
    for _ in 0..<25 where heading == nil {
      transcript(app).swipeDown()
      sleep(1)
      heading = middleHeading(app)
    }
    let anchor = try XCTUnwrap(heading, "no step heading near the middle of the screen")
    for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
      measureStep("rotate scrolled up") { XCUIDevice.shared.orientation = orientation }
      XCTAssertTrue(isVisible(anchor, in: app), "\(anchor) left the screen")
    }
  }

  // MARK: Helpers

  /// The transcript's visible band: under the navigation bar and above the composer.
  @MainActor
  private func readingBand(_ app: XCUIApplication) -> (frame: CGRect, texts: [ShownText]) {
    guard let snapshot = try? transcript(app).snapshot() else { return (.zero, []) }
    var frame = snapshot.frame
    let composer = app.descendants(matching: .any)["composer"].firstMatch
    if composer.exists { frame.size.height = composer.frame.minY - frame.minY }
    let bar = app.navigationBars.firstMatch
    if bar.exists, bar.frame.maxY > frame.minY {
      frame = frame.divided(atDistance: bar.frame.maxY - frame.minY, from: .minYEdge).remainder
    }
    var texts: [ShownText] = []
    Self.collectTexts(snapshot, into: &texts)
    return (frame, texts)
  }

  private struct ShownText {
    let frame: CGRect
    let label: String
  }

  private static func collectTexts(_ node: any XCUIElementSnapshot, into texts: inout [ShownText]) {
    if node.elementType == .staticText, !node.frame.isEmpty {
      texts.append(ShownText(frame: node.frame, label: node.label))
    }
    for child in node.children { collectTexts(child, into: &texts) }
  }

  /// Whether the transcript's last text ends above the composer: nothing is left below it.
  @MainActor
  private func isAtBottom(_ app: XCUIApplication) -> Bool {
    let band = readingBand(app)
    guard let lowest = band.texts.map(\.frame.maxY).max() else { return false }
    return lowest <= band.frame.maxY + 2
  }

  /// The seeded step heading (unique per turn) nearest the middle of the visible band.
  @MainActor
  private func middleHeading(_ app: XCUIApplication) -> String? {
    let band = readingBand(app)
    return band.texts
      .filter {
        $0.label.hasPrefix("Step ")
          && band.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
      }
      .min { abs($0.frame.midY - band.frame.midY) < abs($1.frame.midY - band.frame.midY) }?.label
  }

  @MainActor
  private func isVisible(_ label: String, in app: XCUIApplication) -> Bool {
    let band = readingBand(app)
    return band.texts.contains { $0.label == label && band.frame.intersects($0.frame) }
  }

  private var longIndex: Int {
    ProcessInfo.processInfo.environment["OMNIGENT_LONG"].flatMap(Int.init) ?? 1
  }

  private var serverHost: String {
    let url = URL(string: server)
    return (url?.host() ?? "127.0.0.1") + (url?.port.map { ":\($0)" } ?? "")
  }

  /// The id `seed-large-fixtures.py` gives long transcript `index`.
  private static func longSession(_ index: Int) -> String {
    SHA256.hash(data: Data("perf-long/\(index)".utf8))
      .map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined().prefix(32).description
  }

  private static var transcriptIdentifier: NSPredicate {
    NSPredicate(format: "identifier BEGINSWITH 'transcript-'")
  }

  @MainActor
  private func transcript(_ app: XCUIApplication) -> XCUIElement {
    app.scrollViews.matching(Self.transcriptIdentifier).firstMatch
  }

  /// The app on the local server with the frame monitor, the long transcript open and settled.
  @MainActor
  private func launch() throws -> XCUIApplication {
    let environment = ProcessInfo.processInfo.environment
    guard environment["OMNIGENT_LONG"] != nil || environment["OMNIGENT_UITEST_SESSION"] != nil
    else {
      throw XCTSkip("Seed with `just apple-seed-large` and set TEST_RUNNER_OMNIGENT_LONG.")
    }
    let style = ProcessInfo.processInfo.environment["OMNIGENT_STYLE"] ?? "chat"
    let app = XCUIApplication()
    app.launchArguments += [
      "-omnigent.lastServer", server, "-ApplePersistenceIgnoreState", "YES",
      "-OmnigentNoNotificationPrompt", "YES", "-OmnigentFrameMonitor", "YES",
      "-OmnigentPerfDriver", "YES",
      "-omnigent:transcript-style", style,
      "-OmnigentOpenURL", "omnigent://\(serverHost)/c/\(Self.longSession(longIndex))",
    ]
    XCUIDevice.shared.orientation = isPad ? .landscapeLeft : .portrait
    app.launch()
    XCTAssertTrue(transcript(app).waitForExistence(timeout: 60), "the transcript did not open")
    // The first layout, the framing scroll and late-sizing rows.
    sleep(4)
    return app
  }

  /// Runs `action` inside one frame-monitor interval, then lets the motion finish.
  @MainActor
  private func measureStep(_ name: String, settle: UInt32 = 3, _ action: () -> Void) {
    XCTContext.runActivity(named: name) { activity in
      unsafe notify_post("ai.omnigent.perf.begin")
      action()
      sleep(settle)
      unsafe notify_post("ai.omnigent.perf.end")
      sleep(1)
      let app = XCUIApplication()
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.lifetime = .keepAlways
      activity.add(shot)
      XCTAssertTrue(showsRows(app), "the transcript is blank after \(name)")
    }
  }

  /// Whether a transcript has text inside its visible frame. Kept-alive tabs hold hidden
  /// transcripts too, and split panes' overlays make texts fail `isHittable`.
  @MainActor
  private func showsRows(_ app: XCUIApplication) -> Bool {
    app.scrollViews.matching(Self.transcriptIdentifier).allElementsBoundByIndex.contains {
      guard let snapshot = try? $0.snapshot() else { return false }
      return Self.hasText(in: snapshot, within: snapshot.frame)
    }
  }

  private static func hasText(in node: any XCUIElementSnapshot, within frame: CGRect) -> Bool {
    if node.elementType == .staticText, !node.frame.isEmpty, node.frame.intersects(frame) {
      return true
    }
    return node.children.contains { hasText(in: $0, within: frame) }
  }

  /// Opens `link` as the system does, accepting its "Open in" prompt.
  @MainActor
  private func openURL(_ link: String) throws {
    XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: link), "bad link \(link)"))
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let open = springboard.buttons["Open"]
    if open.waitForExistence(timeout: 5) { open.tap() }
  }
}
