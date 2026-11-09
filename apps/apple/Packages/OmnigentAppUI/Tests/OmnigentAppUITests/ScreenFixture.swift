import AppKit
import Foundation
import OmnigentViewTesting
import SwiftUI
import Testing

/// Lets the screen's tasks and the core's events run until `condition` holds. A main-actor test
/// must suspend for that: a nested run loop doesn't drain the main queue the test itself runs on.
@MainActor
func settle<Content: View>(
  _ screen: OffscreenWindow<Content>, until description: String,
  timeout: Duration = .seconds(5), _ condition: () -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for \(description)")
      return
    }
    screen.settle(0.005)
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Lets the screen's tasks run for a moment with nothing particular to wait for.
@MainActor
func pause<Content: View>(_ screen: OffscreenWindow<Content>, _ time: Duration = .milliseconds(60))
  async throws
{
  let deadline = ContinuousClock.now + time
  while ContinuousClock.now < deadline {
    screen.settle(0.005)
    try await Task.sleep(for: .milliseconds(5))
  }
}

/// Every title on a menu, at any depth.
@MainActor
func menuTitles(_ menu: NSMenu) -> [String] {
  menu.items.flatMap { item in
    [item.title] + (item.submenu.map(menuTitles) ?? [])
  }
}

/// Opens the menu at `point`, requiring it to offer `title`.
@MainActor
func menu<Content: View>(
  _ screen: OffscreenWindow<Content>, at point: CGPoint, offering title: String
) throws -> NSMenu {
  let menu = try screen.openMenu(point)
  guard menuTitles(menu).contains(title) else {
    throw OffscreenWindowError.notFound("\(title) in \(menuTitles(menu))")
  }
  return menu
}
