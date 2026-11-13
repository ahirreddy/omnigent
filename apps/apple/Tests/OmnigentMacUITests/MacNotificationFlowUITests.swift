import XCTest

/// Notifications the app posts through macOS, on the local server: the offline demo has no
/// stream of session updates for the core to notify from. They need the app's notifications
/// allowed on the machine, and the app reads that when Settings shows it.
final class MacNotificationFlowUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  override func tearDown() {
    continueAfterFailure = true
    super.tearDown()
  }

  /// A turn that ends in a session other than the one on screen posts a notification with the
  /// reply, and clicking it in Notification Center opens that session. The list is where it
  /// is read: the banner lasts five seconds and gives UI automation no element.
  @MainActor
  func testANotificationPostsAndOpensItsSession() throws {
    let live = MacLiveUITestSupport(self)
    let session = try live.fixtureSession()
    let other = try live.pagedSession()
    let app = live.launch()
    defer { app.terminate() }
    try requireAllowedNotifications(live, app)
    live.open(session, in: app)
    // An earlier run's notification may still be listed; a new one has its own identifier.
    showNotificationCenter(true)
    let earlier = Set(listedNotifications().allElementsBoundByIndex.map(\.identifier))
    showNotificationCenter(false)

    // Leave before the reply ends: the session on screen never notifies.
    let message = "Notify me \(UUID().uuidString.prefix(6))"
    live.send(message, in: app)
    live.assertShows(message, in: app)
    live.open(other, in: app)

    // The core waits ten seconds after a turn ends before it notifies.
    var posted: String?
    for _ in 0..<15 where posted == nil {
      showNotificationCenter(true)
      _ = live.waitUntil(timeout: 5) {
        posted = listedNotifications().allElementsBoundByIndex.map(\.identifier)
          .first { !earlier.contains($0) }
        return posted != nil
      }
      if posted == nil { showNotificationCenter(false) }
    }
    let identifier = try XCTUnwrap(posted, "no notification for the session")
    let notification = listedNotifications().matching(identifier: identifier).firstMatch
    XCTAssertTrue(
      notification.label.contains("local mock model"),
      "the notification does not carry the reply: \(notification.label)")

    // Among older notifications of the app the first click only spreads the stack out.
    let transcript = live.element("transcript-\(session)", in: app)
    for _ in 0..<2 where !transcript.exists && notification.exists {
      notification.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
      _ = transcript.appears(within: 10)
    }
    XCTAssertTrue(transcript.exists, "the notification did not open its session")
    live.assertRunning(app, "after opening the session from its notification")
  }

  /// The fixture session's notifications listed in Notification Center, while it is open:
  /// each is labeled with the app, the session's title and the body.
  @MainActor
  private func listedNotifications() -> XCUIElementQuery {
    XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
      .descendants(matching: .any)
      .matching(NSPredicate(format: "label CONTAINS %@", ", UI test fixture, "))
  }

  /// Opens or closes Notification Center with the menu bar's clock.
  @MainActor
  private func showNotificationCenter(_ shows: Bool) {
    let list = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
      .dialogs["Notification Center"]
    let clock = XCUIApplication(bundleIdentifier: "com.apple.controlcenter")
      .statusItems["com.apple.menuextra.clock"]
    for _ in 0..<3 where list.exists != shows {
      clock.click()
      _ = shows ? list.appears(within: 5) : list.disappears(within: 5)
    }
    XCTAssertEqual(list.exists, shows, "Notification Center did not \(shows ? "open" : "close")")
  }

  /// Opens Settings' Notifications tab, where the app reads its permission, and skips the flow
  /// unless notifications are allowed. Closes Settings again.
  @MainActor
  private func requireAllowedNotifications(
    _ live: MacLiveUITestSupport, _ app: XCUIApplication
  ) throws {
    let windows = app.windows.count
    app.typeKey(",", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { app.windows.count == windows + 1 }, "no Settings window")
    let settings = app.windows.element(boundBy: 0)
    live.click(settings.toolbars.buttons["Notifications"], "the Notifications tab")
    XCTAssertTrue(
      live.element("settings.notifications.play-sound", in: app).appears(within: 10),
      "no Notifications pane")
    let isAllowed = settings.staticTexts.matching(NSPredicate(format: "value == %@", "Allowed"))
      .firstMatch.appears(within: 5)
    app.typeKey("w", modifierFlags: .command)
    XCTAssertTrue(live.waitUntil { app.windows.count == windows }, "Settings stayed open")
    try XCTSkipUnless(
      isAllowed,
      "Allow the app's notifications on this machine (System Settings > Notifications).")
  }
}
