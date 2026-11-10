import AppKit
import Foundation
import OWLProtocol
import OmnigentInput
import Testing

@testable import OmnigentWebLayer

/// A key as it is pressed: what it types, its key code and the modifiers held.
nonisolated private struct PressedKey: Sendable, CustomTestStringConvertible {
  var characters: String
  var keyCode: UInt16
  var flags: NSEvent.ModifierFlags = []

  var testDescription: String { "\(characters.debugDescription) flags \(flags.rawValue)" }
}

/// Where a key the page gave back goes: the window, the main menu, the responders, or nowhere.
@MainActor
@Suite("Unhandled keys", .serialized)
struct UnhandledKeyRoutingTests {
  /// ⌘A, as the host returns a shortcut the page didn't take.
  private static let commandA = WireEncoder()
    .u64(.nativeKeyCode, 0).u64(.modifiers, InputModifiers.command.rawValue)
    .u64(.character, 97).u64(.unmodifiedCharacter, 97)

  /// Keys that only type: plain, Shift and Option characters.
  nonisolated private static let typedKeys = [
    PressedKey(characters: "e", keyCode: 14), PressedKey(characters: "f", keyCode: 3),
    PressedKey(characters: "d", keyCode: 2), PressedKey(characters: " ", keyCode: 49),
    PressedKey(characters: "E", keyCode: 14, flags: .shift),
    PressedKey(characters: "é", keyCode: 14, flags: .option),
  ]
  /// Escape, Return and the left arrow.
  nonisolated private static let nonTypingKeys = [
    PressedKey(characters: "\u{1B}", keyCode: 53), PressedKey(characters: "\r", keyCode: 36),
    PressedKey(characters: "\u{F702}", keyCode: 123),
  ]

  /// A key-down sent to the page, then returned by the host as one the page did not use.
  private func giveBack(_ key: PressedKey, to host: HostedSurface) throws {
    let event = try Offscreen.keyEvent(
      characters: key.characters, keyCode: key.keyCode, flags: key.flags, window: host.window)
    host.fixture.webView.renderer.forwardKeyEvent(event)
    let unit = UInt64(key.characters.utf16.first ?? 0)
    try host.fixture.receive(
      .keyUnhandled,
      WireEncoder().u64(.nativeKeyCode, UInt64(key.keyCode))
        .u64(.modifiers, InputTranslator.modifiers(key.flags).rawValue)
        .u64(.character, unit).u64(.unmodifiedCharacter, unit))
  }

  /// Makes `item`, in an Edit submenu, the whole main menu until the returned closure runs.
  private func mainMenu(_ item: NSMenuItem, target: MenuActionRecorder) -> () -> Void {
    item.target = target
    let submenu = NSMenu(title: "Edit")
    submenu.addItem(item)
    let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    holder.submenu = submenu
    let menu = NSMenu()
    menu.addItem(holder)
    let previous = NSApp.mainMenu
    NSApp.mainMenu = menu
    return { NSApp.mainMenu = previous }
  }

  @Test("a key AppKit won't rebuild goes nowhere, and the rest reach the view")
  func unhandledKeyNotRebuilt() throws {
    let fixture = ProtocolFixture()
    let renderer = fixture.webView.renderer
    var delivered = 0
    renderer.onUnhandledKeyEvent = { _ in delivered += 1 }
    renderer.forwardUnhandledKey(nil, keyCode: 7)
    #expect(delivered == 0)
    renderer.forwardUnhandledKey(try Offscreen.keyEvent(), keyCode: 0)
    #expect(delivered == 1)
  }

  @Test("a shortcut the page gave back goes to the window first, and doesn't return to the page")
  func unhandledShortcutGoesToTheWindow() throws {
    let window = ShortcutWindow()
    let host = HostedSurface(window: window)
    let (fixture, surface) = (host.fixture, host.surface)
    window.shortcut = { event in
      surface.keyDown(with: event)
      surface.keyUp(with: event)
    }
    let event = try Offscreen.keyEvent(flags: .command, window: window)
    #expect(window.makeFirstResponder(surface))
    #expect(surface.performKeyEquivalent(with: event))
    fixture.sent.removeAll()
    try fixture.receive(.keyUnhandled, Self.commandA)
    #expect(window.shortcuts == 1)
    #expect(host.sink.keyDowns == 1)
    #expect(fixture.sent.isEmpty)
    window.contentView = nil
  }

  @Test("a shortcut the page gave back runs the app's menu item, and goes no further")
  func unhandledShortcutRunsTheMenu() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let target = MenuActionRecorder()
    let item = NSMenuItem(
      title: "Act", action: #selector(MenuActionRecorder.act), keyEquivalent: "a")
    item.target = target
    let menu = NSMenu()
    menu.addItem(item)
    let previous = NSApp.mainMenu
    NSApp.mainMenu = menu
    defer { NSApp.mainMenu = previous }
    let event = try Offscreen.keyEvent(flags: .command, window: window)
    #expect(window.makeFirstResponder(surface))
    #expect(surface.performKeyEquivalent(with: event))
    try fixture.receive(.keyUnhandled, Self.commandA)
    #expect(target.runs == 1)
    #expect(host.sink.keyDowns == 0)
    window.contentView = nil
  }

  @Test(
    "a typed character the page gave back is not a shortcut and stops there",
    arguments: typedKeys)
  private func typedKeyIsNotAShortcut(key: PressedKey) throws {
    let host = HostedSurface()
    let target = MenuActionRecorder()
    // An item without Globe is how NSMenu matches the system's Globe items.
    let item = NSMenuItem(
      title: "Emoji & Symbols", action: #selector(MenuActionRecorder.act),
      keyEquivalent: key.characters.lowercased())
    item.keyEquivalentModifierMask = key.flags
    let restore = mainMenu(item, target: target)
    defer { restore() }
    try giveBack(key, to: host)
    #expect(!target.ran)
    #expect(host.sink.keyDowns == 0)
    host.window.contentView = nil
  }

  @Test(
    "a key that types nothing still reaches the menu and then the responders",
    arguments: nonTypingKeys)
  private func nonTypingKeyReachesResponders(key: PressedKey) throws {
    let host = HostedSurface()
    let target = MenuActionRecorder()
    let item = NSMenuItem(
      title: "Act", action: #selector(MenuActionRecorder.act), keyEquivalent: "e")
    let restore = mainMenu(item, target: target)
    defer { restore() }
    try giveBack(key, to: host)
    #expect(!target.ran)
    #expect(host.sink.keyDowns == 1)
    host.window.contentView = nil
  }

  @Test("a chord matching only a Globe item skips the menu unless Globe was held")
  func globeItemNeedsGlobe() throws {
    let host = HostedSurface()
    let target = MenuActionRecorder()
    let item = GlobeMenuItem(
      title: "Center", action: #selector(MenuActionRecorder.act), keyEquivalent: "c")
    item.keyEquivalentModifierMask = [.control]
    let restore = mainMenu(item, target: target)
    defer { restore() }
    try giveBack(PressedKey(characters: "c", keyCode: 8, flags: .control), to: host)
    #expect(!target.ran)
    #expect(host.sink.keyDowns == 1)
    try giveBack(PressedKey(characters: "c", keyCode: 8, flags: [.control, .function]), to: host)
    #expect(target.runs == 1)
    #expect(host.sink.keyDowns == 1)
    host.window.contentView = nil
  }

  @Test("which keys only type")
  func typingKeys() throws {
    #expect(UnhandledKeyRouting.typesText(try Offscreen.keyEvent(characters: "e")))
    for chord: NSEvent.ModifierFlags in [.command, .control, .function] {
      #expect(
        !UnhandledKeyRouting.typesText(try Offscreen.keyEvent(characters: "e", flags: chord)))
    }
    // A dead key has no characters yet.
    #expect(!UnhandledKeyRouting.typesText(try Offscreen.keyEvent(characters: "")))
  }

  @Test("which menu items are Globe items, and which keys they keep from the menu")
  func globeItems() throws {
    let globe = GlobeMenuItem(title: "Emoji & Symbols", action: nil, keyEquivalent: "e")
    globe.keyEquivalentModifierMask = []
    let submenu = NSMenu()
    submenu.addItem(globe)
    let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    holder.submenu = submenu
    let menu = NSMenu()
    menu.addItem(NSMenuItem(title: "Edit", action: nil, keyEquivalent: "e"))
    menu.addItem(holder)
    let typed = try Offscreen.keyEvent(characters: "e")
    #expect(UnhandledKeyRouting.hasGlobeItem(in: menu, matching: typed))
    #expect(!UnhandledKeyRouting.mayOffer(typed, to: menu))
    #expect(
      UnhandledKeyRouting.mayOffer(
        try Offscreen.keyEvent(characters: "e", flags: .function), to: menu))
    // Another key, other modifiers, or a key without characters match no Globe item.
    for other in [
      try Offscreen.keyEvent(characters: "x"),
      try Offscreen.keyEvent(characters: "e", flags: .command),
      try Offscreen.keyEvent(characters: ""),
    ] {
      #expect(!UnhandledKeyRouting.hasGlobeItem(in: menu, matching: other))
      #expect(UnhandledKeyRouting.mayOffer(other, to: menu))
    }
  }
}

/// A window that takes every key equivalent, as one with a matching SwiftUI shortcut does.
private final class ShortcutWindow: NSWindow {
  var shortcuts = 0
  var shortcut: (NSEvent) -> Void = { _ in }

  init() {
    super.init(
      contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    shortcuts += 1
    shortcut(event)
    return true
  }
}

/// A menu item reporting a Globe shortcut, which AppKit lets only its own items carry.
nonisolated private final class GlobeMenuItem: NSMenuItem {
  override var keyEquivalentModifierMask: NSEvent.ModifierFlags {
    get { super.keyEquivalentModifierMask.union(.function) }
    set { super.keyEquivalentModifierMask = newValue }
  }
}

private final class MenuActionRecorder: NSObject {
  private(set) var runs = 0
  var ran: Bool { runs > 0 }
  @objc func act() { runs += 1 }
}
