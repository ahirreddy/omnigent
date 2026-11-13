import AppKit
import Foundation
import OWLProtocol
import OWLProtocolCallers
import OmnigentInput
import Testing

@testable import OmnigentWebLayer

/// An Edit menu action as AppKit names it, and the command the page runs for it.
nonisolated private struct EditAction: Sendable, CustomTestStringConvertible {
  var selectorName: String
  var command: UInt64

  var selector: Selector { NSSelectorFromString(selectorName) }
  var testDescription: String { selectorName }
}

/// An Edit menu shortcut: the letter pressed with Command, its key code, and its action.
nonisolated private struct EditShortcut: Sendable, CustomTestStringConvertible {
  var key: String
  var keyCode: UInt16
  var action: EditAction

  var testDescription: String { "⌘\(key.uppercased()) \(action.selectorName)" }
}

/// The Edit menu's actions while a page has the keyboard: Undo, Redo, the pasteboard and Select
/// All run in the page, after the page has had its chance at the key.
@MainActor
@Suite("Web surface editing", .serialized)
struct WebSurfaceEditingTests {
  /// Every action of the standard Edit menu, by the selector its item sends.
  nonisolated private static let actions = [
    EditAction(selectorName: "undo:", command: OWLEditCommand.undo.rawValue),
    EditAction(selectorName: "redo:", command: OWLEditCommand.redo.rawValue),
    EditAction(selectorName: "cut:", command: OWLEditCommand.cut.rawValue),
    EditAction(selectorName: "copy:", command: OWLEditCommand.copy.rawValue),
    EditAction(selectorName: "paste:", command: OWLEditCommand.paste.rawValue),
    EditAction(
      selectorName: "pasteAsPlainText:", command: OWLEditCommand.pasteAndMatchStyle.rawValue),
    EditAction(selectorName: "delete:", command: OWLEditCommand.delete.rawValue),
    EditAction(selectorName: "selectAll:", command: OWLEditCommand.selectAll.rawValue),
  ]

  /// ⌘Z, ⌘X, ⌘C, ⌘V and ⌘A, with the US key codes.
  nonisolated private static let shortcuts = [
    EditShortcut(key: "z", keyCode: 6, action: actions[0]),
    EditShortcut(key: "x", keyCode: 7, action: actions[2]),
    EditShortcut(key: "c", keyCode: 8, action: actions[3]),
    EditShortcut(key: "v", keyCode: 9, action: actions[4]),
    EditShortcut(key: "a", keyCode: 0, action: actions[7]),
  ]

  /// An Edit menu item for `action`. No window is key in a test, so the item names the surface,
  /// which a real Edit item finds as the key window's first responder.
  private func menuItem(_ action: EditAction, key: String = "", for surface: WebSurfaceView)
    -> NSMenuItem
  {
    let item = NSMenuItem(title: action.selectorName, action: action.selector, keyEquivalent: key)
    item.target = surface
    return item
  }

  /// Makes `item`, in an Edit submenu, the whole main menu until the returned closure runs.
  private func mainMenu(_ item: NSMenuItem) -> () -> Void {
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

  /// The host returning `shortcut` as a key the page did not use.
  private func giveBack(_ shortcut: EditShortcut, to fixture: ProtocolFixture) throws {
    let unit = UInt64(shortcut.key.utf16.first ?? 0)
    try fixture.receive(
      .keyUnhandled,
      WireEncoder().u64(.nativeKeyCode, UInt64(shortcut.keyCode))
        .u64(.modifiers, InputModifiers.command.rawValue)
        .u64(.character, unit).u64(.unmodifiedCharacter, unit))
  }

  @Test("the editing command's numbers on the wire are stable")
  func numberingIsStable() {
    #expect(OWL_PROTOCOL_MINOR_EDITING == 6)
    #expect(OWL_PROTOCOL_MINOR >= OWL_PROTOCOL_MINOR_EDITING)
    #expect(OWLMessageKind.editCommand.rawValue == 102)
    #expect(OWLField.editCommand.rawValue == 130)
    #expect(OWLHostErrorCode.editFailed.rawValue == 12)
    #expect(Self.actions.map(\.command) == Array(1...8))
    // Every command the client can send is one of them, each a different one.
    #expect(Set(WebEditingCommand.allCases.map(\.wire.rawValue)) == Set(1...8))
  }

  @Test("a host runs only the editing commands this version defines")
  func knownCommands() {
    for command in WebEditingCommand.allCases {
      #expect(owl_edit_command_is_known_in_c(command.wire.rawValue))
    }
    for unknown: UInt64 in [0, 9, 130, .max] {
      #expect(!owl_edit_command_is_known_in_c(unknown), "\(unknown)")
    }
  }

  @Test("each Edit menu action sends its command to the page", arguments: actions)
  private func actionSendsItsCommand(action: EditAction) throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    #expect(WebSurfaceView.editingCommand(for: action.selector)?.wire.rawValue == action.command)
    #expect(NSApp.sendAction(action.selector, to: surface, from: nil))
    #expect(fixture.sent.count == 1)
    let sent = try #require(fixture.sent.first)
    #expect(sent.kind == .editCommand)
    #expect(sent.target == fixture.webView.id)
    #expect(sent.fields.u64(.editCommand) == action.command)
    #expect(fixture.webView.lastError == nil)
    window.contentView = nil
  }

  @Test("a host older than 1.6 is sent no editing command, and the Edit menu is disabled")
  func olderHostIsNotSentCommands() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    fixture.session.hostMinor = UInt64(OWL_PROTOCOL_MINOR_EDITING) - 1
    var blocked = 0
    fixture.webView.onEvent = { event in
      if case .featureBlocked = event { blocked += 1 }
    }
    #expect(window.makeFirstResponder(surface))
    fixture.sent.removeAll()
    #expect(!fixture.session.supportsEditingCommands)
    #expect(!fixture.webView.canPerformEditingCommands)
    for action in Self.actions {
      #expect(!surface.validateUserInterfaceItem(menuItem(action, for: surface)))
      #expect(NSApp.sendAction(action.selector, to: surface, from: nil))
    }
    // An action that arrives anyway is reported, not sent.
    #expect(fixture.sent.isEmpty)
    #expect(blocked == Self.actions.count)
    guard case .featureBlocked? = fixture.webView.lastError else {
      Issue.record("expected featureBlocked, got \(String(describing: fixture.webView.lastError))")
      return
    }
    window.contentView = nil
  }

  @Test("a page that is not live is sent no editing command and reports nothing")
  func notLivePageIsNotSentCommands() {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    #expect(window.makeFirstResponder(surface))
    fixture.sent.removeAll()
    for status: WebView.Status in [.waitingForHost, .creating, .unavailable(.notReady), .closed] {
      fixture.webView.status = status
      for action in Self.actions {
        #expect(!surface.validateUserInterfaceItem(menuItem(action, for: surface)))
        #expect(NSApp.sendAction(action.selector, to: surface, from: nil))
      }
    }
    #expect(fixture.sent.isEmpty)
    #expect(fixture.webView.lastError == nil)
    window.contentView = nil
  }

  @Test("the Edit menu's items are enabled only while the page has the keyboard and is live")
  func validationFollowsFocusAndState() {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let items = Self.actions.map { menuItem($0, for: surface) }
    let menu = NSMenu(title: "Edit")
    for item in items { menu.addItem(item) }

    // Another view has the keyboard: the page's surface answers no.
    #expect(!surface.editsPage)
    #expect(items.allSatisfy { !surface.validateUserInterfaceItem($0) })
    menu.update()
    #expect(items.allSatisfy { !$0.isEnabled })

    #expect(window.makeFirstResponder(surface))
    #expect(surface.editsPage)
    #expect(items.allSatisfy { surface.validateUserInterfaceItem($0) })
    menu.update()
    #expect(items.allSatisfy { $0.isEnabled })

    // The host went away under a view that still has the keyboard.
    fixture.session.state = .stopped
    #expect(!fixture.session.supportsEditingCommands)
    #expect(items.allSatisfy { !surface.validateUserInterfaceItem($0) })
    menu.update()
    #expect(items.allSatisfy { !$0.isEnabled })

    // An action that is not an editing command is not this rule's to refuse.
    let other = NSMenuItem(
      title: "Cancel", action: #selector(NSResponder.cancelOperation(_:)), keyEquivalent: "")
    #expect(WebSurfaceView.editingCommand(for: other.action) == nil)
    #expect(WebSurfaceView.editingCommand(for: nil) == nil)
    #expect(surface.validateUserInterfaceItem(other))
    window.contentView = nil
  }

  @Test(
    "the page sees an editing shortcut first, and one it gives back runs the Edit menu's action",
    arguments: shortcuts)
  private func pageSeesTheShortcutFirst(shortcut: EditShortcut) throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    let restore = mainMenu(menuItem(shortcut.action, key: shortcut.key, for: surface))
    defer { restore() }
    #expect(window.makeFirstResponder(surface))
    fixture.sent.removeAll()

    let event = try Offscreen.keyEvent(
      characters: shortcut.key, keyCode: shortcut.keyCode, flags: .command, window: window)
    #expect(surface.performKeyEquivalent(with: event))
    // Only the key went to the page: a page that handles it keeps it, and nothing else runs.
    #expect(!fixture.sent.isEmpty)
    #expect(fixture.sent.allSatisfy { $0.kind == .inputKey })

    fixture.sent.removeAll()
    try giveBack(shortcut, to: fixture)
    #expect(fixture.sent.map(\.kind) == [.editCommand])
    #expect(fixture.last(.editCommand)?.u64(.editCommand) == shortcut.action.command)
    #expect(host.sink.keyDowns == 0)
    window.contentView = nil
  }

  @Test("a shortcut given back by a page on an older host runs no editing command")
  func olderHostShortcutRunsNothing() throws {
    let host = HostedSurface()
    let (fixture, surface, window) = (host.fixture, host.surface, host.window)
    fixture.session.hostMinor = UInt64(OWL_PROTOCOL_MINOR_EDITING) - 1
    let copy = Self.shortcuts[2]
    let restore = mainMenu(menuItem(copy.action, key: copy.key, for: surface))
    defer { restore() }
    #expect(window.makeFirstResponder(surface))
    let event = try Offscreen.keyEvent(
      characters: copy.key, keyCode: copy.keyCode, flags: .command, window: window)
    #expect(surface.performKeyEquivalent(with: event))
    fixture.sent.removeAll()
    try giveBack(copy, to: fixture)
    // The disabled item does not run, so nothing is sent and nothing is reported.
    #expect(fixture.sent.isEmpty)
    #expect(fixture.webView.lastError == nil)
    window.contentView = nil
  }
}
