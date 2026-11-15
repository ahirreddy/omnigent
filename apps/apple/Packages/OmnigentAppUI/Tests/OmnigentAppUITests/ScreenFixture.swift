import AppKit
import Foundation
import OmnigentViewTesting
import OmnigentViewTextReading
import SwiftUI
import Testing

/// Lets the screen's tasks and the core's events run until `condition` holds. A main-actor test
/// must suspend for that: a nested run loop doesn't drain the main queue the test itself runs on.
@MainActor
func settle<Content: View>(
  _ screen: OffscreenWindow<Content>, until description: String,
  timeout: Duration = .seconds(5), _ condition: () -> Bool
) async throws {
  if await !screen.waitUntil(timeout: timeout, condition) {
    Issue.record("timed out waiting for \(description)")
  }
}

/// Lets the screen's tasks and the core's events run until the window shows `text`.
@MainActor
func settle<Content: View>(
  _ screen: OffscreenWindow<Content>, untilShowing text: String, contains: Bool = false,
  timeout: Duration = .seconds(5)
) async throws {
  func isShowing() throws -> Bool {
    contains ? try screen.shownText().contains { $0.contains(text) } : try screen.shows(text)
  }
  if try await !screen.waitUntil(timeout: timeout, isShowing) {
    Issue.record("timed out waiting to show \(text) in \(try screen.shownText().prefix(60))")
  }
}

/// Lets the screen's tasks run until the window is at rest, or for `time` while work keeps
/// coming. A task's later `Task.sleep` is not waited for.
@MainActor
func pause<Content: View>(_ screen: OffscreenWindow<Content>, _ time: Duration = .milliseconds(60))
  async throws
{
  await screen.settleTasks(limit: time)
}

/// The window's controls once they have stopped moving: three reads agree, each taken with the
/// window at rest, and none moved for 50 ms. A page that loads, a tab that opens and a banner
/// that arrives lay the window out over several updates, and a click must land where a control is.
@MainActor
func settledControlFrames<Content: View>(_ screen: OffscreenWindow<Content>) async throws
  -> [CGRect]
{
  var frames = screen.controlFrames
  var unchangedReads = 0
  var unchangedSince = ContinuousClock.now
  let deadline = ContinuousClock.now + .seconds(5)
  // The core's events come from its own threads, so a window at rest can still change.
  while unchangedReads < 3 || ContinuousClock.now - unchangedSince < .milliseconds(50) {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting for the controls to stop moving")
      break
    }
    await screen.settleTasks(limit: .milliseconds(50))
    let latest = screen.controlFrames
    if latest != frames { unchangedSince = .now }
    unchangedReads = latest == frames ? unchangedReads + 1 : 0
    frames = latest
  }
  return frames
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

/// The context menu of a row of the screen's first list, as a right click on the row opens it.
@MainActor
func contextMenu<Content: View>(
  ofListRow row: Int, in screen: OffscreenWindow<Content>
) throws -> NSMenu {
  let list = try #require(screen.allViews.lazy.compactMap { $0 as? NSTableView }.first)
  try #require(row < list.numberOfRows, "row \(row) of \(list.numberOfRows)")
  let frame = list.rect(ofRow: row)
  let center = CGPoint(x: frame.midX, y: frame.midY)
  let event = try #require(
    NSEvent.mouseEvent(
      with: .rightMouseDown, location: list.convert(center, to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: screen.activeWindow.windowNumber, context: nil, eventNumber: 1,
      clickCount: 1, pressure: 1))
  // The menu belongs to the row's content, or to the table around it. A sheet's list is
  // reached here too, which a hit test from the window's own root is not.
  var view: NSView? = unsafe list.hitTest(list.convert(center, to: list.superview))
  while let current = view {
    if let menu = current.menu(for: event) { return menu }
    view = unsafe current.superview
  }
  throw OffscreenWindowError.notFound("a context menu on row \(row)")
}

/// The menu at `point`, once it offers `title`. What a menu lists can arrive after the screen
/// shows or after the pick that changes it (an agent's models are read when it is chosen), so
/// this opens it again until the title is there.
@MainActor
func menu<Content: View>(
  _ screen: OffscreenWindow<Content>, at point: CGPoint, onceOffering title: String,
  timeout: Duration = .seconds(5)
) async throws -> NSMenu {
  let deadline = ContinuousClock.now + timeout
  while true {
    do {
      return try menu(screen, at: point, offering: title)
    } catch let error as OffscreenWindowError {
      guard ContinuousClock.now < deadline else { throw error }
    }
    try await pause(screen)
  }
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

/// The middle of the element identified `identifier`, from the top left of the screen's root
/// view, once two reads in a row agree: where to click a control whose place moves with the
/// layout. SwiftUI builds its accessibility tree only once an assistive client says it is
/// there, so this says so first.
@MainActor
func center<Content: View>(
  of identifier: String, in screen: OffscreenWindow<Content>, timeout: TimeInterval = 2
) throws -> CGPoint {
  let setter = NSSelectorFromString("accessibilitySetValue:forAttribute:")
  _ = unsafe NSApp.perform(setter, with: true, with: "AXEnhancedUserInterface")
  defer { _ = unsafe NSApp.perform(setter, with: false, with: "AXEnhancedUserInterface") }
  screen.settle(0.2)
  let deadline = Date().addingTimeInterval(timeout)
  var point = try accessibilityCenter(of: identifier, in: screen)
  while Date() < deadline {
    screen.settle(0.03)
    let latest = try accessibilityCenter(of: identifier, in: screen)
    if latest == point { break }
    point = latest
  }
  return point
}

/// The middle of the element identified `identifier` in the accessibility tree as it is now.
@MainActor
private func accessibilityCenter<Content: View>(
  of identifier: String, in screen: OffscreenWindow<Content>
) throws -> CGPoint {
  func attribute(_ name: String, of element: NSObject) -> Any? {
    element.responds(to: NSSelectorFromString(name)) ? element.value(forKey: name) : nil
  }
  let window = screen.activeWindow
  let root = try #require(window.contentView)
  var pending: [Any] = [root]
  var seen = Set<ObjectIdentifier>()
  while let next = pending.popLast() {
    guard let element = next as? NSObject, seen.insert(ObjectIdentifier(element)).inserted
    else { continue }
    if attribute("accessibilityIdentifier", of: element) as? String == identifier,
      let onScreen = (attribute("accessibilityFrame", of: element) as? NSValue)?.rectValue
    {
      let frame = root.convert(window.convertFromScreen(onScreen), from: nil)
      return CGPoint(x: frame.midX, y: frame.midY)
    }
    pending.append(contentsOf: attribute("accessibilityChildren", of: element) as? [Any] ?? [])
  }
  throw OffscreenWindowError.notFound(identifier)
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

/// The controls that start under `view`, in reading order. A list's rows keep their buttons out
/// of the accessibility tree, so a test knows one there by where it is; a disabled control is
/// not among them at all.
@MainActor
func controls<Content: View>(
  under view: NSView, in screen: OffscreenWindow<Content>
) -> [CGRect] {
  let bottom = view.convert(view.bounds, to: screen.activeWindow.contentView).maxY
  return screen.controlFrames.filter { $0.minY >= bottom }
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

/// Picks the `index`th segment of the screen's only segmented control, as a click on it does.
@MainActor
func chooseSegment<Content: View>(_ index: Int, on screen: OffscreenWindow<Content>) throws {
  let control = try #require(screen.allViews.compactMap { $0 as? NSSegmentedControl }.first)
  control.selectedSegment = index
  control.sendAction(control.action, to: control.target)
}
