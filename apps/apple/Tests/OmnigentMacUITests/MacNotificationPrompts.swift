import XCTest

/// The system's "Notifications" permission banners. The app and its browser helpers each ask
/// once per machine, and until answered a banner covers the window's top right corner: a click
/// there opens System Settings instead of reaching the app.
@MainActor
enum MacNotificationPrompts {
  /// Launches in a row that showed no banner; after two, later launches no longer wait for one.
  private static var quietLaunches = 0

  /// Answers every permission banner on screen with Don't Allow.
  /// - Parameter seconds: How long to wait for a first banner, which shows just after launch.
  static func decline(waiting seconds: TimeInterval) {
    let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
    let prompts = center.groups.matching(
      NSPredicate(format: "label CONTAINS %@", "Notifications may include"))
    let wait = quietLaunches >= 2 ? 0 : seconds
    var declined = 0
    while declined < 6, prompts.firstMatch.appears(within: declined == 0 ? wait : 2) {
      guard decline(prompts.firstMatch, in: center) else { return }
      declined += 1
    }
    if seconds > 0 { quietLaunches = declined == 0 ? quietLaunches + 1 : 0 }
  }

  /// Chooses Options > Don't Allow on one banner; its controls show while the pointer is on it.
  /// Everything is clicked by position: the banners give UI automation no hit point.
  private static func decline(_ prompt: XCUIElement, in center: XCUIApplication) -> Bool {
    let label = prompt.label
    middle(of: prompt).hover()
    let options = center.descendants(matching: .any).matching(
      NSPredicate(format: "title == %@ OR label == %@", "Options", "Options")
    ).firstMatch
    guard options.appears(within: 5) else {
      XCTFail("no Options on the banner \(label)\n\(center.debugDescription)")
      return false
    }
    middle(of: options).click()
    let dontAllow = center.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "Don"))
      .firstMatch
    guard dontAllow.appears(within: 5) else {
      XCTFail("no Don't Allow for the banner \(label)\n\(center.debugDescription)")
      return false
    }
    middle(of: dontAllow).click()
    let gone = center.groups.matching(NSPredicate(format: "label == %@", label)).firstMatch
    XCTAssertTrue(gone.disappears(within: 5), "the banner \(label) stayed")
    return !gone.exists
  }

  private static func middle(of element: XCUIElement) -> XCUICoordinate {
    element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
  }
}
