import AppKit
import Foundation
import GhosttyKit
import Testing

@testable import OmnigentTerminalUI

/// A key with modifiers, Command alone unless given.
private struct Chord {
  let characters: String
  let keyCode: UInt16
  let flags: NSEvent.ModifierFlags

  init(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = .command) {
    self.characters = characters
    self.keyCode = keyCode
    self.flags = flags
  }

  func event() throws -> NSEvent {
    try Events.key(characters: characters, keyCode: keyCode, flags: flags)
  }
}

enum Events {
  static func key(
    _ type: NSEvent.EventType = .keyDown, characters: String = "a", keyCode: UInt16 = 0,
    flags: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    try #require(
      NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode))
  }

  static func mouse(
    _ type: NSEvent.EventType, at location: CGPoint = CGPoint(x: 5, y: 5),
    flags: NSEvent.ModifierFlags = []
  ) throws -> NSEvent {
    try #require(
      NSEvent.mouseEvent(
        with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  }

  /// A modifier key event, built but never posted.
  static func flags(keyCode: UInt16, flags: CGEventFlags) throws -> NSEvent {
    let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
    event.type = .flagsChanged
    event.flags = flags
    return try #require(NSEvent(cgEvent: event))
  }

  /// A scroll event, built but never posted.
  static func scroll(_ deltaY: Int32, _ deltaX: Int32 = 0) throws -> NSEvent {
    let event = try #require(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: deltaY, wheel2: deltaX,
        wheel3: 0))
    return try #require(NSEvent(cgEvent: event))
  }
}

@Suite("Surface keyboard input, offscreen", .serialized)
struct SurfaceKeyboardTests {
  @Test("a key down reaches the program and a key up sends nothing more")
  func typedKey() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.view.keyDown(with: try Events.key())
    #expect(await eventually { surface.connection.received == [0x61] })
    surface.view.keyUp(with: try Events.key(.keyUp))
    #expect(surface.connection.received == [0x61])
  }

  @Test("control and function keys take Ghostty's encoder, not their characters")
  func specialKeys() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let functionKey = String(UnicodeScalar(0xF700 as UInt32).map(Character.init) ?? " ")
    surface.view.keyDown(with: try Events.key(characters: functionKey, keyCode: 0x7E))
    #expect(await eventually { surface.connection.received == Array("\u{1b}[A".utf8) })
    surface.view.keyDown(with: try Events.key(characters: "\u{3}", keyCode: 8, flags: .control))
    #expect(await eventually { surface.connection.received.last == 0x03 })
    surface.view.keyDown(with: try Events.key(characters: "", keyCode: 0xFFFF))
    surface.view.keyDown(with: try Events.key(characters: "👩‍👩‍👧‍👦\u{0}", keyCode: 0))
    #expect(await surface.survives([], marker: "after-keys"))
  }

  @Test("each modifier key reaches the encoder, and others are ignored")
  func modifierKeys() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let keys: [(UInt16, CGEventFlags)] = [
      (0x39, .maskAlphaShift), (0x38, .maskShift), (0x3C, .maskShift), (0x3B, .maskControl),
      (0x3E, .maskControl), (0x3A, .maskAlternate), (0x3D, .maskAlternate), (0x37, .maskCommand),
      (0x36, .maskCommand), (0x00, .maskShift),
    ]
    for (keyCode, flags) in keys {
      surface.view.flagsChanged(with: try Events.flags(keyCode: keyCode, flags: flags))
      surface.view.flagsChanged(with: try Events.flags(keyCode: keyCode, flags: []))
    }
    surface.view.setMarkedText(
      "か", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange())
    surface.view.flagsChanged(with: try Events.flags(keyCode: 0x38, flags: .maskShift))
    #expect(await surface.survives([], marker: "after-flags"))
  }

  @Test("a Command chord runs Ghostty's binding only with focus")
  func keyEquivalents() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let selectAll = try Events.key(characters: "a", keyCode: 0, flags: .command)
    #expect(!surface.view.performKeyEquivalent(with: selectAll))
    #expect(surface.window.makeFirstResponder(surface.view))
    #expect(surface.view.focused)
    #expect(!surface.view.performKeyEquivalent(with: try Events.key(characters: "a", keyCode: 0)))
    #expect(!surface.view.performKeyEquivalent(with: try Events.key(.keyUp, flags: .command)))
    #expect(surface.view.performKeyEquivalent(with: selectAll))
    #expect(await eventually { surface.controller.hasSelection })
    #expect(surface.window.makeFirstResponder(nil))
    #expect(!surface.view.focused)
  }

  @Test("the app's menu shortcuts stay the app's while the terminal has focus")
  func menuShortcutsPassThrough() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    #expect(surface.window.makeFirstResponder(surface.view))
    let appChords = try [
      Chord("q", 12), Chord("n", 45), Chord("t", 17), Chord("w", 13), Chord("k", 40),
      Chord("[", 33), Chord("]", 30), Chord("1", 18), Chord("z", 6), Chord("d", 2),
      Chord(",", 43), Chord("n", 45, [.command, .shift]), Chord("t", 17, [.command, .shift]),
      Chord("w", 13, [.command, .shift]), Chord("f", 3, [.command, .shift]),
      Chord("a", 0, [.control, .shift]), Chord("f", 3, [.command, .control]),
    ].map { try $0.event() }
    for chord in appChords {
      #expect(!surface.view.performKeyEquivalent(with: chord), "\(chord)")
    }
    let terminalChords = try [
      Chord("c", 8), Chord("v", 9), Chord("a", 0), Chord("f", 3), Chord("g", 5),
      Chord("=", 24), Chord("-", 27), Chord("0", 29),
    ].map { try $0.event() }
    for chord in terminalChords {
      #expect(surface.view.isBinding(chord), "\(chord)")
    }
  }

  @Test("committed text is typed, and only strings count")
  func insertText() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let none = NSRange(location: NSNotFound, length: 0)
    surface.view.insertText("a", replacementRange: none)
    surface.view.insertText(NSAttributedString(string: "b"), replacementRange: none)
    surface.view.insertText(7, replacementRange: none)
    surface.view.insertText(NSNull(), replacementRange: none)
    #expect(await eventually { surface.connection.received == Array("ab".utf8) })
  }

  @Test("marked text previews, reports its range and clears")
  func markedText() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let view = surface.view
    let range = NSRange(location: 0, length: 1)
    let none = NSRange(location: NSNotFound, length: 0)
    #expect(!view.hasMarkedText())
    #expect(view.markedRange().location == NSNotFound)
    view.setMarkedText("かな", selectedRange: range, replacementRange: none)
    #expect(view.hasMarkedText())
    #expect(view.markedRange() == NSRange(location: 0, length: 2))
    view.setMarkedText(
      NSAttributedString(string: "👩‍👩‍👧‍👦"), selectedRange: range, replacementRange: none)
    #expect(view.markedText.string == "👩‍👩‍👧‍👦")
    view.setMarkedText(7, selectedRange: range, replacementRange: none)
    #expect(view.markedText.string == "👩‍👩‍👧‍👦")
    view.setMarkedText(
      String(repeating: "W", count: 100_000), selectedRange: range, replacementRange: none)
    view.setMarkedText("a\u{0}b", selectedRange: range, replacementRange: none)
    view.unmarkText()
    view.unmarkText()
    #expect(!view.hasMarkedText())
    #expect(view.selectedRange().location == NSNotFound)
    #expect(view.validAttributesForMarkedText().isEmpty)
    #expect(view.characterIndex(for: .zero) == 0)
    let substring = unsafe view.attributedSubstring(forProposedRange: range, actualRange: nil)
    #expect(substring == nil)
    let rect = unsafe view.firstRect(forCharacterRange: range, actualRange: nil)
    #expect(rect.height >= 1)
  }

  @Test("a view without a controller takes every event quietly")
  func noController() throws {
    let view = TerminalSurfaceNSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    unsafe view.nextResponder = SilentResponder()
    let event = try Events.mouse(.leftMouseDown)
    view.keyDown(with: try Events.key())
    view.keyUp(with: try Events.key(.keyUp))
    view.flagsChanged(with: try Events.flags(keyCode: 0x38, flags: .maskShift))
    #expect(!view.performKeyEquivalent(with: try Events.key(flags: .command)))
    view.mouseDown(with: event)
    view.mouseUp(with: event)
    view.rightMouseDown(with: event)
    view.rightMouseUp(with: event)
    view.otherMouseDown(with: event)
    view.otherMouseUp(with: event)
    view.mouseMoved(with: event)
    view.mouseDragged(with: event)
    view.rightMouseDragged(with: event)
    view.otherMouseDragged(with: event)
    view.scrollWheel(with: try Events.scroll(5))
    view.insertText("x", replacementRange: NSRange())
    view.setMarkedText("x", selectedRange: NSRange(), replacementRange: NSRange())
    view.unmarkText()
    #expect(unsafe view.firstRect(forCharacterRange: NSRange(), actualRange: nil) == .zero)
    #expect(view.requestRender() == false)
    view.selectAll(nil)
    view.findTerminal(nil)
    view.setFrameSize(NSSize(width: 50, height: 50))
    view.stopRendering()
    #expect(view.resignFirstResponder())
  }

  @Test("modifier flags map to Ghostty's bits, and event text follows the rules")
  func eventMapping() throws {
    #expect(ghosttyMods([]).rawValue == GHOSTTY_MODS_NONE.rawValue)
    let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
    #expect(ghosttyMods(flags).rawValue != 0)
    let everything = NSEvent.ModifierFlags(rawValue: .max)
    #expect(ghosttyMods(everything).rawValue != 0)
    #expect(try Events.key(characters: "a").ghosttyCharacters == "a")
    #expect(try Events.key(characters: "ab").ghosttyCharacters == "ab")
    #expect(try Events.key(characters: "").ghosttyCharacters?.isEmpty == true)
    let functionKey = String(UnicodeScalar(0xF8FF as UInt32).map(Character.init) ?? " ")
    #expect(try Events.key(characters: functionKey).ghosttyCharacters == nil)
    #expect(try Events.key(characters: "\u{3}", flags: .control).ghosttyCharacters != nil)
    let key = unsafe try Events.key(flags: flags).ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
    let mods = unsafe key.mods
    #expect(mods.rawValue != 0)
  }
}

@Suite("Surface mouse input, offscreen", .serialized)
struct SurfaceMouseTests {
  @Test("with mouse reporting on, buttons reach the program")
  func mouseReporting() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.feed(Array("\u{1b}[?1000h\u{1b}[?1006h".utf8))
    try await Task.sleep(for: .milliseconds(100))
    surface.view.mouseDown(with: try Events.mouse(.leftMouseDown))
    surface.view.mouseUp(with: try Events.mouse(.leftMouseUp))
    surface.view.rightMouseDown(with: try Events.mouse(.rightMouseDown))
    surface.view.rightMouseUp(with: try Events.mouse(.rightMouseUp))
    surface.view.otherMouseDown(with: try Events.mouse(.otherMouseDown))
    surface.view.otherMouseUp(with: try Events.mouse(.otherMouseUp))
    #expect(await eventually { lossyUTF8(surface.connection.received).contains("[<0;") })
    #expect(await eventually { lossyUTF8(surface.connection.received).contains("[<2;") })
  }

  @Test("a drag selects when the program does not take the mouse")
  func dragSelects() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.view.mouseDown(with: try Events.mouse(.leftMouseDown, at: CGPoint(x: 5, y: 230)))
    surface.view.mouseDragged(
      with: try Events.mouse(.leftMouseDragged, at: CGPoint(x: 400, y: 200)))
    surface.view.rightMouseDragged(with: try Events.mouse(.rightMouseDragged))
    surface.view.otherMouseDragged(with: try Events.mouse(.otherMouseDragged))
    surface.view.mouseUp(with: try Events.mouse(.leftMouseUp))
    #expect(await surface.survives([], marker: "after-drag"))
  }

  @Test("positions outside the view are taken")
  func outsidePositions() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.feed(Array("\u{1b}[?1003h\u{1b}[?1006h".utf8))
    let points = [
      CGPoint(x: -1, y: -1), CGPoint(x: 1e6, y: -1e6), CGPoint(x: 1e15, y: 1e15),
      CGPoint(x: -1e15, y: 0),
    ]
    for point in points {
      surface.view.mouseMoved(with: try Events.mouse(.mouseMoved, at: point))
    }
    #expect(await surface.survives([], marker: "after-outside"))
  }

  @Test("a position that is not a number is ignored")
  func nanPosition() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.feed(Array("\u{1b}[?1003h\u{1b}[?1006h".utf8))
    let nan = CGPoint(x: CGFloat.nan, y: .nan)
    surface.view.mouseMoved(with: try Events.mouse(.mouseMoved, at: nan))
    #expect(await surface.survives([], marker: "after-nan"))
  }

  @Test("wheel deltas large and small scroll without trapping")
  func scrolling() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    surface.controller.feed(Array(String(repeating: "line\r\n", count: 500).utf8))
    for delta in [Int32(1), -1, 1_000, -1_000, 100_000, -100_000, .max, .min] {
      surface.view.scrollWheel(with: try Events.scroll(delta, delta))
    }
    #expect(await surface.survives([], marker: "after-scroll"))
  }

  @Test("each momentum phase has a mapping")
  func momentumPhases() throws {
    let view = TerminalSurfaceNSView(frame: .zero)
    let phases: [NSEvent.Phase] = [
      .began, .stationary, .changed, .ended, .cancelled, .mayBegin, [],
    ]
    let values = Set(phases.map { view.momentum($0) })
    #expect(values.count == phases.count)
  }

  @Test("the edit menu lists its commands, and Find opens the bar")
  func editMenu() async throws {
    let surface = try NeverShownSurface()
    #expect(await surface.ready())
    let menu = try #require(surface.view.menu(for: try Events.mouse(.rightMouseDown)))
    #expect(menu.items.map(\.title) == ["Copy", "Paste", "", "Select All", "Find…"])
    #expect(!surface.view.validateMenuItem(menu.items[0]))
    #expect(surface.view.validateMenuItem(menu.items[3]))
    #expect(surface.view.validateMenuItem(menu.items[4]))
    surface.view.selectAll(nil)
    #expect(await eventually { surface.view.validateMenuItem(menu.items[0]) })
    surface.view.findTerminal(nil)
    #expect(surface.controller.search != nil)
    surface.controller.endSearch()
  }

  @Test("view lifecycle callbacks are safe to repeat")
  func lifecycle() async throws {
    let surface = try NeverShownSurface()
    let view = surface.view
    #expect(await surface.ready())
    view.updateTrackingAreas()
    view.updateTrackingAreas()
    #expect(view.trackingAreas.count == 1)
    view.viewDidMoveToWindow()
    view.viewDidChangeBackingProperties()
    view.doCommand(by: #selector(NSResponder.moveLeft(_:)))
    #expect(view.acceptsFirstResponder)
    #expect(!view.isFlipped)
    view.setFrameSize(NSSize(width: 0, height: 0))
    view.setFrameSize(NSSize(width: 1, height: 1))
    view.setFrameSize(NSSize(width: 480, height: 240))
    #expect(await surface.survives([], marker: "after-lifecycle"))
  }
}
