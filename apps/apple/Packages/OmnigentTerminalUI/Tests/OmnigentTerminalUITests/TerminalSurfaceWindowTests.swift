import AppKit
import Foundation
import OmnigentGhosttyKit
import OmnigentViewTesting
import SwiftUI
import Testing

@testable import OmnigentTerminalUI

/// A surface as a tab shows it: hosted by SwiftUI in a window that takes real events, so hit
/// testing, the first responder and the responder chain are the app's own.
struct WindowedSurface {
  let connection = EchoTerminalConnection(prompt: "$ ", banner: "ready")
  let controller: TerminalSurfaceController
  let screen: OffscreenWindow<TerminalSurfaceRepresentable>

  init(width: CGFloat = 480, height: CGFloat = 240) throws {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    controller = try TerminalSurfaceController(connection: connection)
    screen = OffscreenWindow(
      TerminalSurfaceRepresentable(controller: controller), width: width, height: height)
  }

  /// Runs the window and the surface's tasks until `condition` holds, or five seconds.
  func settles(_ condition: () -> Bool) async -> Bool {
    await eventually {
      screen.settle(0.005)
      return condition()
    }
  }

  /// Whether the banner has reached the screen.
  func ready() async -> Bool {
    await settles { controller.visibleText().contains("ready") }
  }

  /// The grid libghostty lays out now, whatever the controller last reported.
  var ghosttyGrid: TerminalGridSize? {
    guard let surface = unsafe controller.surface else { return nil }
    let size = unsafe ghostty_surface_size(surface)
    return TerminalGridSize(columns: Int(size.columns), rows: Int(size.rows))
  }

  /// Sends the window a mouse event at a point measured from its top left.
  func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws {
    let event = try #require(
      NSEvent.mouseEvent(
        with: type, location: screen.host.convert(point, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: screen.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
        pressure: type == .leftMouseUp ? 0 : 1))
    // Key, as after any click, so a menu command finds the terminal through the responder chain.
    screen.window.makeKey()
    screen.window.sendEvent(event)
  }

  /// Sends the window a wheel event over a point measured from its top left. A wheel event
  /// carries a screen point, which the window reads as its own; positive `pixels` scroll up.
  func scroll(pixels: Int32, over point: CGPoint) throws {
    let inWindow = screen.host.convert(point, to: nil)
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: pixels, wheel2: 0,
        wheel3: 0))
    let screenHeight = try #require(NSScreen.screens.first).frame.height
    event.location = CGPoint(x: inWindow.x, y: screenHeight - inWindow.y)
    let wheel = try #require(NSEvent(cgEvent: event))
    let placed = wheel.locationInWindow
    try #require(abs(placed.x - inWindow.x) < 1 && abs(placed.y - inWindow.y) < 1, "\(placed)")
    screen.window.sendEvent(wheel)
    screen.settle(0.02)
  }

  /// Presses a chord as the menu pass does, before any view gets the key. Returns whether a
  /// view took it.
  func chord(
    _ characters: String, keyCode: UInt16, flags: NSEvent.ModifierFlags = .command
  ) throws -> Bool {
    let event = try #require(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: screen.window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    let handled = screen.window.performKeyEquivalent(with: event)
    screen.settle(0.02)
    return handled
  }

  /// Chooses an item of the edit menu a right click on the terminal opens. AppKit sends an item
  /// with no target of its own down the responder chain from the view the menu opened on,
  /// unless that view turns the item off.
  /// - Returns: Whether the item was on and a responder took its action.
  func chooseEditItem(_ title: String) throws -> Bool {
    let menu = try #require(try screen.contextMenu(at: CGPoint(x: 100, y: 100)))
    let item = try #require(menu.items.first { $0.title == title })
    let action = try #require(item.action)
    guard controller.view.validateMenuItem(item) else { return false }
    let taken = controller.view.tryToPerform(action, with: item)
    screen.settle()
    return taken
  }

  /// The number of the first numbered line on screen, as `numberedLines` wrote them.
  var firstLineNumber: Int? {
    controller.visibleText().split(separator: "\n")
      .first { $0.hasPrefix("line-") }
      .flatMap { Int($0.dropFirst("line-".count)) }
  }

  /// Output of `count` lines, each "line-N".
  static func numberedLines(_ count: Int) -> [UInt8] {
    Array((1...count).map { "line-\($0)\r\n" }.joined().utf8)
  }
}

// The package's test runs name their suites; these two names end as suites they already name.
@Suite("The terminal in a window, by mouse, menu and wheel", .serialized)
struct WindowedSurfaceMouseTests {
  private let inside = CGPoint(x: 100, y: 100)

  @Test("a click gives the terminal the keyboard, and what is typed then reaches the program")
  func clickTakesTheKeyboard() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    #expect(surface.screen.window.firstResponder !== surface.controller.view)
    #expect(!surface.controller.view.focused)
    try surface.screen.click(inside)
    #expect(surface.screen.window.firstResponder === surface.controller.view)
    #expect(surface.controller.view.focused)
    try surface.screen.type("a")
    #expect(await surface.settles { surface.connection.received == [0x61] })
  }

  @Test("dragging across the banner selects it, and the edit menu's Copy copies it")
  func dragSelectsAndCopies() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    #expect(!surface.controller.hasSelection)
    // The banner is the first row: from its first cell to well past its last.
    try surface.mouse(.leftMouseDown, at: CGPoint(x: 3, y: 8))
    try surface.mouse(.leftMouseDragged, at: CGPoint(x: 120, y: 8))
    try surface.mouse(.leftMouseDragged, at: CGPoint(x: 240, y: 8))
    try surface.mouse(.leftMouseUp, at: CGPoint(x: 240, y: 8))
    #expect(await surface.settles { surface.controller.hasSelection })
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == nil)
    #expect(try surface.chooseEditItem("Copy"))
    let copied = SystemSideEffects.pasteboard.string(forType: .string)
    #expect(copied?.trimmingCharacters(in: .whitespacesAndNewlines) == "ready")
    #expect(surface.connection.received.isEmpty, "selecting and copying type nothing")
  }

  @Test("with nothing selected, the edit menu's Copy leaves the clipboard alone")
  func copyWithoutSelection() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    try surface.screen.click(inside)
    SystemSideEffects.pasteboard.setString("kept", forType: .string)
    #expect(try !surface.chooseEditItem("Copy"), "Copy is off with nothing selected")
    #expect(SystemSideEffects.pasteboard.string(forType: .string) == "kept")
  }

  @Test("the edit menu's Select All selects, and its Copy then copies the whole screen")
  func selectAllFromTheMenu() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    try surface.screen.click(inside)
    #expect(!surface.controller.hasSelection)
    #expect(try surface.chooseEditItem("Select All"))
    #expect(await surface.settles { surface.controller.hasSelection })
    #expect(try surface.chooseEditItem("Copy"))
    let copied = SystemSideEffects.pasteboard.string(forType: .string) ?? ""
    #expect(copied.contains("ready"))
    #expect(copied.contains("$"))
  }

  @Test("the edit menu's Paste types the clipboard into the program")
  func pasteFromTheMenu() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    try surface.screen.click(inside)
    SystemSideEffects.pasteboard.setString("from-clipboard", forType: .string)
    #expect(try surface.chooseEditItem("Paste"))
    #expect(await surface.settles { surface.connection.received == Array("from-clipboard".utf8) })
  }

  @Test("the edit menu's Find opens the search, and Escape in the terminal closes it")
  func findFromTheMenu() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    try surface.screen.click(inside)
    #expect(surface.controller.search == nil)
    #expect(try surface.chooseEditItem("Find\u{2026}"))
    #expect(await surface.settles { surface.controller.search != nil })
    try surface.screen.press(keyCode: 53, characters: "\u{1B}")
    #expect(await surface.settles { surface.controller.search == nil })
    #expect(surface.connection.received.isEmpty, "the Escape closed the search, not typed")
  }

  @Test("a larger window tells the program its new grid")
  func resizeSendsTheGrid() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    let before = try #require(surface.connection.sizes.last)
    #expect(before == surface.controller.gridSize)
    surface.screen.window.setContentSize(NSSize(width: 800, height: 480))
    #expect(await surface.settles { surface.connection.sizes.last != before })
    let after = try #require(surface.connection.sizes.last)
    #expect(after.columns > before.columns, "\(before) then \(after)")
    #expect(after.rows > before.rows, "\(before) then \(after)")
    #expect(after == surface.controller.gridSize)
    #expect(after == surface.ghosttyGrid)
  }

  @Test("the wheel scrolls back to earlier lines, and forward to the newest again")
  func wheelScrollsBack() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    surface.controller.feed(WindowedSurface.numberedLines(200))
    #expect(await surface.settles { surface.controller.visibleText().contains("line-200") })
    let newest = try #require(surface.firstLineNumber)
    #expect(newest > 150, "only the last lines fit: \(newest)")
    try surface.scroll(pixels: 300, over: inside)
    #expect(await surface.settles { (surface.firstLineNumber ?? newest) < newest })
    #expect(!surface.controller.visibleText().contains("line-200"))
    try surface.scroll(pixels: -100_000, over: inside)
    #expect(await surface.settles { surface.controller.visibleText().contains("line-200") })
    #expect(surface.connection.received.isEmpty, "scrolling back types nothing")
  }
}

@Suite("The terminal in a window, by chord", .serialized)
struct WindowedSurfaceKeyboardTests {
  private let inside = CGPoint(x: 100, y: 100)

  @Test("Command-plus, minus and zero change the text size, and the program gets each grid")
  func textSizeChords() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    let start = try #require(surface.ghosttyGrid)
    #expect(surface.connection.sizes.last == start)
    #expect(try !surface.chord("=", keyCode: 24), "not the terminal's before it has the keyboard")
    #expect(surface.ghosttyGrid == start)

    try surface.screen.click(inside)
    #expect(try surface.chord("=", keyCode: 24))
    #expect(await surface.settles { (surface.ghosttyGrid?.columns ?? .max) < start.columns })
    let larger = try #require(surface.ghosttyGrid)
    #expect(await surface.settles { surface.connection.sizes.last == larger })
    #expect(surface.controller.gridSize == larger)

    #expect(try surface.chord("-", keyCode: 27))
    #expect(await surface.settles { surface.ghosttyGrid == start })
    #expect(await surface.settles { surface.connection.sizes.last == start })

    #expect(try surface.chord("=", keyCode: 24))
    #expect(try surface.chord("=", keyCode: 24))
    #expect(await surface.settles { (surface.ghosttyGrid?.columns ?? .max) < larger.columns })
    #expect(try surface.chord("0", keyCode: 29))
    #expect(await surface.settles { surface.ghosttyGrid == start })
    #expect(await surface.settles { surface.connection.sizes.last == start })
    #expect(surface.connection.received.isEmpty, "none of the chords was typed")
  }

  @Test("Command-F opens the search; Command-G and Shift-Command-G step through its matches")
  func searchChords() async throws {
    let surface = try WindowedSurface()
    defer { surface.screen.close() }
    #expect(await surface.ready())
    surface.controller.feed(Array("needle one\r\nneedle two\r\nneedle three\r\n".utf8))
    #expect(await surface.settles { surface.controller.visibleText().contains("needle three") })
    try surface.screen.click(inside)
    #expect(try surface.chord("f", keyCode: 3))
    #expect(await surface.settles { surface.controller.search != nil })
    surface.controller.updateSearch("needle")
    #expect(await surface.settles { surface.controller.search?.total == 3 })

    #expect(try surface.chord("g", keyCode: 5))
    #expect(await surface.settles { surface.controller.search?.selected != nil })
    let first = try #require(surface.controller.search?.selected)
    #expect(try surface.chord("g", keyCode: 5))
    #expect(await surface.settles { surface.controller.search?.selected != first })
    let second = try #require(surface.controller.search?.selected)
    #expect(try surface.chord("G", keyCode: 5, flags: [.command, .shift]))
    #expect(await surface.settles { surface.controller.search?.selected == first }, "\(second)")
    #expect(surface.connection.received.isEmpty, "none of the chords was typed")
  }
}
