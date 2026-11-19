import AppKit
import XCTest

/// The sidebar hides and shows at once from the toolbar's button, Control-Command-S and the View
/// menu, without a session switch: by the columns' frames, and by what the window draws where
/// the sidebar was.
final class MacSidebarToggleFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A Nord-based custom theme whose sidebar is tinted rather than translucent.
  private static let opaqueSidebarTheme = [
    "-omnigent:ui-theme-palette", plistString(#""custom""#),
    "-omnigent:custom-theme",
    plistString(
      ##"{"basePalette":"nord","accent":"#5e81ac","darkAccent":"#88c0d0","tint":"#eceff4","##
        + ##""darkTint":"#2e3440","contrast":50,"translucentSidebar":false}"##),
  ]

  /// `text` as a plist string literal, so a launch argument keeps its JSON quotes.
  private static func plistString(_ text: String) -> String {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  @MainActor
  func testToolbarButtonHidesAndShowsTheSidebar() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    SidebarToggleCheck(live: live, app: app).run(.toolbar)
  }

  @MainActor
  func testKeysHideAndShowTheSidebar() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    SidebarToggleCheck(live: live, app: app).run(.keys)
  }

  @MainActor
  func testViewMenuHidesAndShowsTheSidebar() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    SidebarToggleCheck(live: live, app: app).run(.menu)
  }

  /// Option-Command-[ and the command palette's Toggle conversations sidebar.
  @MainActor
  func testPaletteCommandHidesAndShowsTheSidebar() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo()
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    SidebarToggleCheck(live: live, app: app).run(.paletteKeys, .palette, rounds: 2)
  }

  @MainActor
  func testToolbarButtonHidesAndShowsATintedSidebar() {
    let live = MacLiveUITestSupport(self)
    let app = live.launchDemo(arguments: Self.opaqueSidebarTheme)
    defer { app.terminate() }
    live.openDemo("demo-notes", in: app)
    SidebarToggleCheck(live: live, app: app).run(.toolbar)
  }

  /// On a live server, with the seeded fixture session open.
  @MainActor
  func testToolbarButtonHidesAndShowsTheSidebarOnALiveSession() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let app = live.launch(arguments: Self.opaqueSidebarTheme)
    defer { app.terminate() }
    live.open(session, in: app)
    SidebarToggleCheck(live: live, app: app).run(.toolbar, .keys)
  }
}

/// Hides and shows the shown window's sidebar, checking each change lands within about a second:
/// the slide takes a quarter of one.
@MainActor
private struct SidebarToggleCheck {
  enum Way: String {
    case toolbar = "the toolbar's sidebar button"
    case keys = "Control-Command-S"
    case menu = "the View menu's sidebar item"
    case paletteKeys = "Option-Command-["
    case palette = "the command palette"
  }

  let live: MacLiveUITestSupport
  let app: XCUIApplication

  /// How long a change may take to show.
  static let deadline: TimeInterval = 1.2
  /// The mean gray-level change, out of 255, where the sidebar was, below which the window
  /// still draws what it did.
  static let changed: Double = 4

  private var window: XCUIElement { app.windows.firstMatch }
  private var sidebar: XCUIElement { live.element("sidebar", in: app) }
  /// The composer, which spans the detail column.
  private var detail: XCUIElement { live.composer(in: app) }

  func run(_ ways: Way..., rounds: Int = 3) {
    XCTAssertTrue(sidebar.appears(within: 10), "no sidebar\n\(app.debugDescription)")
    XCTAssertTrue(detail.appears(within: 10), "no composer")
    // The window can still be laying out its first session.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let sidebarFrame = sidebar.frame
    let detailFrame = detail.frame
    // Below the toolbar row, which a toggle draws again either way.
    let region = sidebarFrame.insetBy(dx: 8, dy: 0).inset(top: 70, bottom: 12)
    let shown = grays(in: region)
    live.shot(app, "shown")
    for round in 1...rounds {
      for way in ways {
        let step = "\(way.rawValue), round \(round)"
        toggle(way, hiding: true)
        assertHidden(
          step, region: region, shown: shown, sidebarFrame: sidebarFrame,
          detailFrame: detailFrame)
        toggle(way, hiding: false)
        assertShown(
          step, region: region, shown: shown, sidebarFrame: sidebarFrame,
          detailFrame: detailFrame)
      }
    }
    live.assertRunning(app, "after toggling the sidebar")
  }

  private func toggle(_ way: Way, hiding: Bool) {
    switch way {
    case .toolbar:
      guard let button = toolbarToggle() else {
        XCTFail("no sidebar button in the toolbar\n\(app.debugDescription)")
        return
      }
      button.click()
    case .keys:
      app.typeKey("s", modifierFlags: [.command, .control])
    case .menu:
      live.click(app.menuBars.menuBarItems["View"], "the View menu")
      guard let item = live.hittable(app.menuItems.matching(identifier: "toggleSidebar:")) else {
        XCTFail("no sidebar item in the View menu\n\(app.debugDescription)")
        return
      }
      XCTContext.runActivity(named: "View menu item: \(item.title)") { _ in item.click() }
    case .paletteKeys:
      app.typeKey("[", modifierFlags: [.command, .option])
    case .palette:
      let palette = live.element("command-palette", in: app)
      app.typeKey("k", modifierFlags: .command)
      XCTAssertTrue(palette.appears(within: 10), "no palette")
      app.typeText("Toggle conversations sidebar")
      let entry = live.element("palette-result-sidebar", in: app)
      XCTAssertTrue(entry.appears(within: 10), "the palette has no sidebar entry")
      app.typeKey(.return, modifierFlags: [])
      XCTAssertTrue(palette.disappears(within: 10), "the palette stayed open")
    }
  }

  /// The system's sidebar button in the toolbar.
  private func toolbarToggle() -> XCUIElement? {
    live.hittable(
      app.toolbars.buttons.matching(
        NSPredicate(format: "label IN %@", ["Hide Sidebar", "Show Sidebar"])))
  }

  /// `element`'s frame, or `nil` once it is gone: a frame read as it goes fails the test.
  private func frame(of element: XCUIElement) -> CGRect? {
    (try? element.snapshot())?.frame
  }

  private func assertHidden(
    _ step: String, region: CGRect, shown: [UInt8], sidebarFrame: CGRect,
    detailFrame: CGRect
  ) {
    let edges = window.frame
    let framesMoved = live.waitUntil(timeout: Self.deadline) {
      let gone = frame(of: sidebar).map { $0.isEmpty || $0.maxX <= edges.minX + 1 } ?? true
      return gone && (frame(of: detail)?.minX ?? .infinity) < detailFrame.minX - 60
    }
    let sidebarNow = frame(of: sidebar).map { "\($0)" } ?? "gone"
    let detailNow = frame(of: detail).map { "\($0)" } ?? "gone"
    if !framesMoved { live.shot(app, "not hidden: \(step)") }
    XCTAssertTrue(
      framesMoved,
      "after \(step) the sidebar did not hide: sidebar \(sidebarNow), composer \(detailNow) "
        + "from \(detailFrame)")
    var change = 0.0
    let drawn = live.waitUntil(timeout: Self.deadline) {
      change = Self.difference(grays(in: region), shown)
      return change.isFinite && change > Self.changed
    }
    if !drawn { live.shot(app, "still drawn: \(step)") }
    XCTAssertTrue(
      drawn, "after \(step) the window still draws the sidebar (change \(change) of 255)")
  }

  private func assertShown(
    _ step: String, region: CGRect, shown: [UInt8], sidebarFrame: CGRect,
    detailFrame: CGRect
  ) {
    let framesBack = live.waitUntil(timeout: Self.deadline) {
      guard let sidebarNow = frame(of: sidebar), let detailNow = frame(of: detail) else {
        return false
      }
      return abs(sidebarNow.maxX - sidebarFrame.maxX) < 2
        && abs(detailNow.minX - detailFrame.minX) < 2
    }
    let sidebarNow = frame(of: sidebar).map { "\($0)" } ?? "gone"
    if !framesBack { live.shot(app, "not shown: \(step)") }
    XCTAssertTrue(
      framesBack,
      "after \(step) the sidebar did not come back: sidebar \(sidebarNow) from \(sidebarFrame)")
    var change = 0.0
    let drawn = live.waitUntil(timeout: Self.deadline) {
      change = Self.difference(grays(in: region), shown)
      return change < Self.changed / 2
    }
    if !drawn { live.shot(app, "not drawn: \(step)") }
    XCTAssertTrue(drawn, "after \(step) the window does not draw the sidebar (change \(change))")
  }

  /// The window's pixels in `rect` (screen points, as accessibility frames are) as gray levels,
  /// one sample every two points.
  private func grays(in rect: CGRect) -> [UInt8] {
    let edges = window.frame
    let screenshot = window.screenshot().image
    // No proposed rectangle: the whole image.
    guard let image = unsafe screenshot.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else { return [] }
    let scale = CGFloat(image.width) / edges.width
    let crop = CGRect(
      x: (rect.minX - edges.minX) * scale, y: (rect.minY - edges.minY) * scale,
      width: rect.width * scale, height: rect.height * scale
    ).integral
    guard let cropped = image.cropping(to: crop) else { return [] }
    let width = max(1, Int(rect.width / 2))
    let height = max(1, Int(rect.height / 2))
    // With no data given, the context allocates and owns its pixels.
    guard
      let context = unsafe CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return [] }
    context.interpolationQuality = .medium
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.makeImage()?.dataProvider?.data else { return [] }
    let bytes = [UInt8](data as Data)
    let rowBytes = context.bytesPerRow
    return (0..<height).flatMap { row in bytes[(row * rowBytes)..<(row * rowBytes + width)] }
  }

  /// The mean gray-level difference between two samplings of one region.
  private static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
    guard first.count == second.count, !first.isEmpty else { return .infinity }
    let total = zip(first, second).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
    return Double(total) / Double(first.count)
  }
}

extension CGRect {
  /// The rectangle less `top` points at its top and `bottom` at its bottom, in accessibility
  /// coordinates, which run down from the screen's top.
  fileprivate func inset(top: CGFloat, bottom: CGFloat) -> CGRect {
    CGRect(x: minX, y: minY + top, width: width, height: max(0, height - top - bottom))
  }
}
