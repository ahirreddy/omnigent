internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// The Edit menu's shortcuts and actions in a page. See DESIGN.md, "Editing commands".
extension Proofs {
  /// The actions the Edit menu must offer, then the ones it may.
  private static let requiredEditActions = [
    "undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
  ]
  private static let optionalEditActions = ["pasteAsPlainText:", "delete:"]

  /// Types into a field, then edits it with the Edit menu's shortcuts and its actions. Replaces
  /// what is on the general pasteboard.
  func editingShortcuts() async throws {
    try await load(Self.formPage, title: "OWL form")
    _ = try await webView.evaluateJavaScript(
      """
      window.chords = '';
      addEventListener('keydown', (e) => {
        if (e.metaKey && e.key.length === 1) window.chords += e.key.toLowerCase();
      }, true); 0
      """)
    click(at: try await center(of: "#name"))
    try await settle(0.2)
    type("hello owl")
    try await field(holds: "hello owl", after: "typing")
    try checkEditMenu()

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    try chord("a")
    try chord("c")
    try await waitUntil("⌘A ⌘C to put the field's text on the pasteboard", timeout: 3) {
      pasteboard.string(forType: .string) == "hello owl"
    }
    try chord("x")
    try await field(holds: "", after: "⌘X")
    try chord("z")
    try await field(holds: "hello owl", after: "⌘Z")
    try chord("z", shift: true)
    try await field(holds: "", after: "⇧⌘Z")
    try chord("v")
    try await field(holds: "hello owl", after: "⌘V")
    let chords = try await webView.evaluateJavaScript("window.chords")
    guard chords == .string("acxzzv") else {
      throw ProofFailure("The page saw the chords \(chords) before the menu, not acxzzv.")
    }

    // An Edit menu item chosen with the mouse sends its action to the first responder.
    try menuAction("selectAll:")
    try menuAction("delete:")
    try await field(holds: "", after: "Edit > Select All and Edit > Delete")
    // Text another part of the app copied pastes into the page.
    pasteboard.clearContents()
    guard pasteboard.setString("from the app", forType: .string) else {
      throw ProofFailure("The general pasteboard refused a string.")
    }
    try menuAction("paste:")
    try await field(holds: "from the app", after: "Edit > Paste")
    Clock.log("editing: the page saw \(chords), then the Edit menu's actions ran in it")
  }

  /// Presses Command and `letter` as AppKit offers a key equivalent to the window.
  private func chord(_ letter: Character, shift: Bool = false) throws {
    guard let window, let keyCode = Self.keyCodes[letter] else {
      throw ProofFailure("No window or key code for ⌘\(letter).")
    }
    let key = String(letter)
    let event = keyEvent(
      .keyDown, keyCode: keyCode, characters: shift ? key.uppercased() : key, unmodified: key,
      modifiers: shift ? [.command, .shift] : .command)
    guard window.performKeyEquivalent(with: event) else {
      throw ProofFailure("Nothing took ⌘\(letter).")
    }
  }

  /// Sends `action` as a menu item without a target does.
  private func menuAction(_ action: String) throws {
    guard NSApp.sendAction(NSSelectorFromString(action), to: nil, from: nil) else {
      throw ProofFailure("No responder took \(action).")
    }
  }

  /// Waits for the form's field to hold `value`.
  private func field(holds value: String, after what: String) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while true {
      let current = try await webView.evaluateJavaScript("document.querySelector('#name').value")
      if current == .string(value) { return }
      guard ContinuousClock.now < deadline else {
        throw ProofFailure("After \(what) the field holds \(current), not '\(value)'.")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  /// The app's Edit menu offers the editing actions, enabled while the page has the keyboard.
  private func checkEditMenu() throws {
    guard let menu = NSApp.mainMenu else { throw ProofFailure("The app has no main menu.") }
    for action in Self.requiredEditActions + Self.optionalEditActions {
      let required = Self.requiredEditActions.contains(action)
      guard let item = Self.item(sending: NSSelectorFromString(action), in: menu) else {
        if required { throw ProofFailure("No menu item sends \(action).") }
        Clock.log("editing: no menu item sends \(action)")
        continue
      }
      guard item.isEnabled else {
        throw ProofFailure("\(item.title) is disabled while the page has the keyboard.")
      }
    }
  }

  /// The item in `menu` or its submenus that sends `action`, with its menu's state up to date.
  private static func item(sending action: Selector, in menu: NSMenu) -> NSMenuItem? {
    menu.update()
    for item in menu.items {
      if item.action == action { return item }
      if let submenu = item.submenu, let match = Self.item(sending: action, in: submenu) {
        return match
      }
    }
    return nil
  }
}
