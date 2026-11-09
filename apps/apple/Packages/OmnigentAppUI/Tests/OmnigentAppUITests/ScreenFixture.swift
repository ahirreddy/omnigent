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

/// One element of what VoiceOver reads on a screen.
@MainActor
struct AccessibleElement {
  let object: AnyObject
  let role: String
  let label: String
  let value: String
  let identifier: String

  /// Everything an assistive tool can read of this element.
  var text: String { [label, value].filter { !$0.isEmpty }.joined(separator: " ") }
}

/// Every accessibility element under the window, including the sidebar's and the panels' own
/// hosting views that a read of the root view's text doesn't reach.
@MainActor
func accessibleElements<Content: View>(_ screen: OffscreenWindow<Content>) -> [AccessibleElement] {
  var found: [AccessibleElement] = []
  var seen = Set<ObjectIdentifier>()
  func visit(_ node: Any) {
    guard let object = node as? NSObject, seen.insert(ObjectIdentifier(object)).inserted,
      let element = object as? any NSAccessibilityProtocol & NSObject
    else { return }
    let role = element.accessibilityRole()?.rawValue ?? ""
    let value = element.accessibilityValue().map { "\($0)" } ?? ""
    found.append(
      AccessibleElement(
        object: element, role: role, label: element.accessibilityLabel() ?? "",
        value: value, identifier: element.accessibilityIdentifier() ?? ""))
    for child in element.accessibilityChildren() ?? [] { visit(child) }
  }
  for view in screen.allViews { visit(view) }
  return found
}

/// All the words the window offers an assistive tool, in every hosting view it holds.
@MainActor
func readableText<Content: View>(_ screen: OffscreenWindow<Content>) -> [String] {
  accessibleElements(screen).map(\.text).filter { !$0.isEmpty }
}

/// Where an element is, from the top left of the screen's root view.
@MainActor
func location<Content: View>(
  of element: AccessibleElement, in screen: OffscreenWindow<Content>
) -> CGRect? {
  guard let source = element.object as? any NSAccessibilityProtocol else { return nil }
  let window = screen.activeWindow
  let inWindow = window.convertFromScreen(source.accessibilityFrame())
  guard let root = window.contentView else { return nil }
  return root.convert(inWindow, from: nil)
}

/// Clicks, with a real mouse down and up, the element labeled or identified `name`.
@MainActor
func click<Content: View>(_ name: String, in screen: OffscreenWindow<Content>) throws {
  let elements = accessibleElements(screen)
  let isNamed: (AccessibleElement) -> Bool = {
    $0.identifier == name || $0.label == name || $0.value == name
  }
  let matches = elements.filter(isNamed)
  let onScreen = matches.compactMap { location(of: $0, in: screen) }.first { !$0.isEmpty }
  guard let frame = onScreen else {
    throw OffscreenWindowError.notFound("\(name) in \(readableText(screen).prefix(80))")
  }
  try screen.click(CGPoint(x: frame.midX, y: frame.midY))
}

/// Presses a keyboard shortcut the way the app delivers it, before the key reaches the focused
/// view. Returns whether anything took it.
@MainActor
@discardableResult
func pressShortcut<Content: View>(
  _ screen: OffscreenWindow<Content>, keyCode: UInt16, characters: String,
  modifiers: NSEvent.ModifierFlags
) throws -> Bool {
  let window = screen.activeWindow
  let event = NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: modifiers,
    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
    context: nil, characters: characters, charactersIgnoringModifiers: characters,
    isARepeat: false, keyCode: keyCode)
  let keyDown = try #require(event)
  let handled = window.performKeyEquivalent(with: keyDown)
  screen.settle(0.02)
  return handled
}
