#if os(macOS)
  public import AppKit
#endif

/// NSEvent to CEF-style input, done in the client so the renderer never sees NSEvents. Pure
/// functions so they are unit-testable.
nonisolated public enum InputTranslator {
  /// Points scrolled by a non-precise wheel tick.
  public static let lineScrollPoints = 40.0

  /// Whether a UTF-16 unit from a keyDown should be inserted as text. Excludes AppKit's
  /// function-key range and control characters other than Return.
  /// - Parameter unit: The unit.
  /// - Returns: Whether it inserts text.
  public static func insertsText(_ unit: UInt16) -> Bool {
    if (0xF700...0xF8FF).contains(unit) { return false }
    if unit == 0x0D { return true }
    return unit >= 0x20 && unit != 0x7F
  }
}

#if os(macOS)
  nonisolated extension InputTranslator {
    /// CEF modifier bits for AppKit flags and the held mouse buttons.
    /// - Parameters:
    ///   - flags: AppKit modifier flags.
    ///   - pressedButtons: `NSEvent.pressedMouseButtons` bits.
    /// - Returns: The modifiers.
    public static func modifiers(_ flags: NSEvent.ModifierFlags, pressedButtons: Int = 0)
      -> InputModifiers
    {
      var result: InputModifiers = []
      if flags.contains(.capsLock) { result.insert(.capsLock) }
      if flags.contains(.shift) { result.insert(.shift) }
      if flags.contains(.control) { result.insert(.control) }
      if flags.contains(.option) { result.insert(.alt) }
      if flags.contains(.command) { result.insert(.command) }
      if flags.contains(.numericPad) { result.insert(.isKeyPad) }
      if pressedButtons & 1 != 0 { result.insert(.leftMouse) }
      if pressedButtons & 2 != 0 { result.insert(.rightMouse) }
      if pressedButtons & 4 != 0 { result.insert(.middleMouse) }
      return result
    }

    /// Translates keyDown, keyUp and flagsChanged. A keyDown becomes a RawKeyDown plus one Char
    /// per inserted UTF-16 unit, as Chromium's own Mac view does; Command chords insert no text.
    /// - Parameter event: The key event.
    /// - Returns: The key events, empty for other event types.
    public static func keyInputs(for event: NSEvent) -> [NativeKeyInput] {
      var flags = modifiers(event.modifierFlags)
      switch event.type {
      case .keyDown:
        if event.isARepeat { flags.insert(.isRepeat) }
        let characters = Array((event.characters ?? "").utf16)
        let unmodified = Array((event.charactersIgnoringModifiers ?? "").utf16)
        var inputs = [
          NativeKeyInput(
            kind: .rawKeyDown, nativeKeyCode: event.keyCode, modifiers: flags,
            character: characters.first ?? 0, unmodifiedCharacter: unmodified.first ?? 0)
        ]
        if !event.modifierFlags.contains(.command) {
          for unit in characters where insertsText(unit) {
            inputs.append(
              NativeKeyInput(
                kind: .char, nativeKeyCode: event.keyCode, modifiers: flags, character: unit,
                unmodifiedCharacter: unmodified.first ?? unit))
          }
        }
        return inputs
      case .keyUp:
        let characters = Array((event.characters ?? "").utf16)
        let unmodified = Array((event.charactersIgnoringModifiers ?? "").utf16)
        return [
          NativeKeyInput(
            kind: .keyUp, nativeKeyCode: event.keyCode, modifiers: flags,
            character: characters.first ?? 0, unmodifiedCharacter: unmodified.first ?? 0)
        ]
      case .flagsChanged:
        guard let flag = modifierFlag(forKeyCode: event.keyCode) else { return [] }
        let pressed = event.modifierFlags.contains(flag)
        return [
          NativeKeyInput(
            kind: pressed ? .rawKeyDown : .keyUp, nativeKeyCode: event.keyCode, modifiers: flags)
        ]
      default:
        return []
      }
    }

    /// The modifier flag a modifier key toggles.
    /// - Parameter keyCode: The virtual key code.
    /// - Returns: The flag, or `nil` for other keys.
    public static func modifierFlag(forKeyCode keyCode: UInt16) -> NSEvent.ModifierFlags? {
      switch keyCode {
      case 56, 60: .shift
      case 59, 62: .control
      case 58, 61: .option
      case 55, 54: .command
      case 57: .capsLock
      default: nil
      }
    }

    /// Translates a mouse or scroll event.
    /// - Parameters:
    ///   - event: The event.
    ///   - location: Its location in the view's top-left coordinates.
    /// - Returns: The pointer event, or `nil` for other event types.
    public static func pointerInput(for event: NSEvent, location: CGPoint) -> PointerInput? {
      let flags = modifiers(
        event.modifierFlags, pressedButtons: NSEvent.pressedMouseButtons | impliedButtons(event))
      var input = PointerInput(kind: .move, location: location, modifiers: flags)
      switch event.type {
      case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .mouseEntered:
        input.kind = .move
      case .mouseExited:
        input.kind = .leave
      case .leftMouseDown, .rightMouseDown, .otherMouseDown:
        input.kind = .press
        input.button = button(for: event)
        input.clickCount = max(1, event.clickCount)
      case .leftMouseUp, .rightMouseUp, .otherMouseUp:
        input.kind = .release
        input.button = button(for: event)
        input.clickCount = max(1, event.clickCount)
      case .scrollWheel:
        input.kind = .wheel
        let factor = event.hasPreciseScrollingDeltas ? 1 : lineScrollPoints
        input.deltaX = event.scrollingDeltaX * factor
        input.deltaY = event.scrollingDeltaY * factor
      default:
        return nil
      }
      return input
    }

    /// The button a drag or press event implies, as a `pressedMouseButtons` bit. Synthesized
    /// events (and events replayed after the hardware state changed) still carry their button.
    /// - Parameter event: The event.
    /// - Returns: The bit, or 0.
    public static func impliedButtons(_ event: NSEvent) -> Int {
      switch event.type {
      case .leftMouseDown, .leftMouseDragged: 1
      case .rightMouseDown, .rightMouseDragged: 2
      case .otherMouseDown, .otherMouseDragged: 4
      default: 0
      }
    }

    private static func button(for event: NSEvent) -> PointerButton {
      switch event.type {
      case .rightMouseDown, .rightMouseUp: .right
      case .otherMouseDown, .otherMouseUp: .middle
      default: .left
      }
    }
  }

  extension PageCursor {
    /// The AppKit cursor that shows this shape.
    public var nsCursor: NSCursor {
      switch self {
      case .pointer, .wait, .none, .help: .arrow
      case .hand: .pointingHand
      case .iBeam: .iBeam
      case .crosshair: .crosshair
      case .resizeLeftRight: .resizeLeftRight
      case .resizeUpDown: .resizeUpDown
      case .notAllowed: .operationNotAllowed
      case .grab: .openHand
      case .grabbing: .closedHand
      }
    }
  }
#endif
