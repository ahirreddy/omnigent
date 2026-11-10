internal import AppKit
internal import OmnigentInput

/// What a key the page declined may still do in the app. See DESIGN.md, "Unhandled keys".
enum UnhandledKeyRouting {
  private static let chordFlags: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

  /// Whether `event` only types a character: a printable key without Command, Control or Globe.
  /// Typing belongs to the page alone and is never a shortcut.
  static func typesText(_ event: NSEvent) -> Bool {
    guard event.modifierFlags.isDisjoint(with: [.command, .control, .function]),
      let unit = event.characters?.utf16.first
    else { return false }
    return unit != 0x0D && InputTranslator.insertsText(unit)
  }

  /// Whether `menu` may be offered `event`. NSMenu runs a Globe-key item (Emoji & Symbols,
  /// Start Dictation, Enter Full Screen) for the same key pressed without Globe.
  static func mayOffer(_ event: NSEvent, to menu: NSMenu) -> Bool {
    event.modifierFlags.contains(.function) || !hasGlobeItem(in: menu, matching: event)
  }

  /// Whether an item in `menu` or its submenus has `event`'s key and modifiers plus Globe.
  static func hasGlobeItem(in menu: NSMenu, matching event: NSEvent) -> Bool {
    guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else {
      return false
    }
    return hasGlobeItem(
      in: menu, key: key, chord: event.modifierFlags.intersection(chordFlags))
  }

  private static func hasGlobeItem(in menu: NSMenu, key: String, chord: NSEvent.ModifierFlags)
    -> Bool
  {
    menu.items.contains { item in
      if let submenu = item.submenu, hasGlobeItem(in: submenu, key: key, chord: chord) {
        return true
      }
      let mask = item.keyEquivalentModifierMask
      return mask.contains(.function) && item.keyEquivalent.lowercased() == key
        && mask.intersection(chordFlags) == chord
    }
  }
}
