internal import AppKit
internal import OWLProtocol
internal import OmnigentInput

extension PointerInput {
  func encoded(origin: OWLInputOrigin) -> WireEncoder {
    WireEncoder()
      .u64(.inputOrigin, origin.rawValue)
      .u64(.mouseKind, kind.rawValue)
      .double(.X, location.x)
      .double(.Y, location.y)
      .u64(.button, button.rawValue)
      .u64(.clickCount, UInt64(max(1, clickCount)))
      .u64(.modifiers, modifiers.rawValue)
      .double(.deltaX, deltaX)
      .double(.deltaY, deltaY)
  }
}

extension NativeKeyInput {
  func encoded(origin: OWLInputOrigin) -> WireEncoder {
    WireEncoder()
      .u64(.inputOrigin, origin.rawValue)
      .u64(.keyKind, kind.rawValue)
      .u64(.nativeKeyCode, UInt64(nativeKeyCode))
      .u64(.modifiers, modifiers.rawValue)
      .u64(.character, UInt64(character))
      .u64(.unmodifiedCharacter, UInt64(unmodifiedCharacter))
  }
}

/// The NSEvent translation itself is shared with the remote browser in `OmnigentInput`.
extension InputTranslator {
  /// Rebuilds an NSEvent for a key the page did not handle, so the app's menus and responders
  /// see it. `template` supplies the characters when available.
  static func unhandledKeyEvent(_ key: UnhandledKey, template: NSEvent?, windowNumber: Int)
    -> NSEvent?
  {
    let modifiers = key.modifiers
    let character = key.character
    let unmodifiedCharacter = key.unmodifiedCharacter
    var flags: NSEvent.ModifierFlags = []
    if modifiers.contains(.shift) { flags.insert(.shift) }
    if modifiers.contains(.control) { flags.insert(.control) }
    if modifiers.contains(.alt) { flags.insert(.option) }
    if modifiers.contains(.command) { flags.insert(.command) }
    if modifiers.contains(.capsLock) { flags.insert(.capsLock) }
    let characters =
      template?.characters ?? String(decoding: character == 0 ? [] : [character], as: UTF16.self)
    let unmodified =
      template?.charactersIgnoringModifiers
      ?? String(
        decoding: unmodifiedCharacter == 0 ? [] : [unmodifiedCharacter], as: UTF16.self)
    return NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: flags,
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil,
      characters: characters, charactersIgnoringModifiers: unmodified,
      isARepeat: modifiers.contains(.isRepeat), keyCode: key.keyCode)
  }
}

/// A key the page did not handle, as the host reports it.
nonisolated struct UnhandledKey: Equatable, Sendable {
  var keyCode: UInt16
  var modifiers: InputModifiers
  var character: UInt16
  var unmodifiedCharacter: UInt16
}

/// Keys an agent can press. See `WebContentRenderer.agentPress(_:modifiers:)`.
nonisolated public enum AgentKey: Sendable, Hashable {
  /// Return.
  case enter
  /// Tab.
  case tab
  /// Escape.
  case escape
  /// Delete backward.
  case backspace
  /// Forward delete.
  case delete
  /// Arrow left.
  case arrowLeft
  /// Arrow right.
  case arrowRight
  /// Arrow up.
  case arrowUp
  /// Arrow down.
  case arrowDown
  /// Home.
  case home
  /// End.
  case end
  /// Page up.
  case pageUp
  /// Page down.
  case pageDown
  /// A printable character.
  case character(Character)

  var nativeKeyCode: UInt16 {
    switch self {
    case .enter: 36
    case .tab: 48
    case .escape: 53
    case .backspace: 51
    case .delete: 117
    case .arrowLeft: 123
    case .arrowRight: 124
    case .arrowDown: 125
    case .arrowUp: 126
    case .home: 115
    case .end: 119
    case .pageUp: 116
    case .pageDown: 121
    case .character(let character): Self.keyCode(for: character) ?? 0
    }
  }

  /// The UTF-16 unit AppKit reports for the key.
  var characterUnit: UInt16 {
    switch self {
    case .enter: 0x0D
    case .tab: 0x09
    case .escape: 0x1B
    case .backspace: 0x7F
    case .delete: 0xF728
    case .arrowLeft: 0xF702
    case .arrowRight: 0xF703
    case .arrowUp: 0xF700
    case .arrowDown: 0xF701
    case .home: 0xF729
    case .end: 0xF72B
    case .pageUp: 0xF72C
    case .pageDown: 0xF72D
    case .character(let character): character.utf16.first ?? 0
    }
  }

  /// US-layout virtual key codes, so keydown listeners see the right `event.code`.
  static func keyCode(for character: Character) -> UInt16? {
    let table: [Character: UInt16] = [
      "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
      "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
      "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
      "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
      ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
    ]
    return table[Character(character.lowercased())]
  }

  /// The key events for one press: RawKeyDown, Char when it inserts text, KeyUp.
  func keyInputs(modifiers: InputModifiers) -> [NativeKeyInput] {
    let unit = characterUnit
    var inputs = [
      NativeKeyInput(
        kind: .rawKeyDown, nativeKeyCode: nativeKeyCode, modifiers: modifiers, character: unit,
        unmodifiedCharacter: unit)
    ]
    if !modifiers.contains(.command), InputTranslator.insertsText(unit) {
      inputs.append(
        NativeKeyInput(
          kind: .char, nativeKeyCode: nativeKeyCode, modifiers: modifiers, character: unit,
          unmodifiedCharacter: unit))
    }
    inputs.append(
      NativeKeyInput(
        kind: .keyUp, nativeKeyCode: nativeKeyCode, modifiers: modifiers, character: unit,
        unmodifiedCharacter: unit))
    return inputs
  }
}
