import CoreGraphics
public import OmnigentCoreFFI
public import OmnigentInput

/// Native input (the shared `OmnigentInput` values) to the core's remote input records: view
/// points to CSS pixels, CEF modifier bits to the core's bits, wheel signs to the DOM's, and
/// macOS key codes to DOM `key` values. The core maps key codes to DOM `code`.
nonisolated public enum RemoteInputMapping {
  /// The core's modifier bits for CEF modifier bits.
  /// - Parameter modifiers: CEF bits.
  /// - Returns: Core bits.
  public static func modifiers(_ modifiers: InputModifiers) -> RemoteModifiers {
    var result: RemoteModifiers = []
    if modifiers.contains(.shift) { result.insert(.shift) }
    if modifiers.contains(.control) { result.insert(.control) }
    if modifiers.contains(.alt) { result.insert(.alt) }
    if modifiers.contains(.command) { result.insert(.meta) }
    if modifiers.contains(.capsLock) { result.insert(.capsLock) }
    if modifiers.contains(.leftMouse) { result.insert(.leftButton) }
    if modifiers.contains(.middleMouse) { result.insert(.middleButton) }
    if modifiers.contains(.rightMouse) { result.insert(.rightButton) }
    return result
  }

  /// A pointer event in viewport CSS pixels. Moves, presses and scrolls over the letterbox are
  /// dropped unless a button is held (a drag that left the page); releases are clamped. The
  /// held-button bits always include a pressed button and never a released one.
  /// - Parameters:
  ///   - input: The view-space event.
  ///   - geometry: The current fit.
  /// - Returns: The event, or `nil` when it is outside the page.
  public static func mouse(_ input: PointerInput, geometry: RemoteViewportGeometry)
    -> MouseInput?
  {
    let dragging = !input.modifiers.isDisjoint(with: [.leftMouse, .middleMouse, .rightMouse])
    let clamp: Bool
    switch input.kind {
    case .release, .leave: clamp = true
    case .move: clamp = dragging
    case .press, .wheel: clamp = false
    }
    guard let point = geometry.cssPoint(for: input.location, clamped: clamp) else { return nil }
    var held = modifiers(input.modifiers)
    switch input.kind {
    case .press: held.insert(buttonBit(input.button))
    case .release: held.remove(buttonBit(input.button))
    case .move, .wheel, .leave: break
    }
    var result = MouseInput(
      kind: kind(input.kind), x: point.x, y: point.y, button: nil, clicks: 0,
      modifiers: held.rawValue, dx: 0, dy: 0)
    switch input.kind {
    case .press, .release:
      result.button = button(input.button)
      result.clicks = UInt8(clamping: max(1, input.clickCount))
    case .wheel:
      // CEF deltas are positive toward the top; the DOM's deltaY is positive scrolling down.
      result.dx = -geometry.cssLength(input.deltaX)
      result.dy = -geometry.cssLength(input.deltaY)
    case .move, .leave:
      break
    }
    return result
  }

  /// The DOM `key` for a macOS virtual key code that names a key rather than typing text.
  /// - Parameter keyCode: `kVK_*`.
  /// - Returns: The key name, or `nil` for keys whose `key` is the text they type.
  public static func namedKey(macKeyCode keyCode: UInt16) -> String? {
    namedMacKeys[keyCode]
  }

  /// The DOM `key` for a USB HID keyboard usage that names a key (iOS hardware keyboards).
  /// - Parameter usage: The HID usage (page 7).
  /// - Returns: The key name, or `nil` for keys whose `key` is the text they type.
  public static func namedKey(hidUsage usage: UInt32) -> String? {
    if (0x3A...0x45).contains(usage) { return "F\(usage - 0x3A + 1)" }
    return namedHIDKeys[usage]
  }

  /// The DOM `key` for a key event: its name, else the characters it typed, else `Dead` (a dead
  /// key that started a composition) or `Unidentified`.
  /// - Parameters:
  ///   - keyCode: `kVK_*`.
  ///   - characters: The event's characters.
  /// - Returns: The DOM key.
  public static func key(macKeyCode keyCode: UInt16, characters: String) -> String {
    if let name = namedKey(macKeyCode: keyCode) { return name }
    if !characters.isEmpty, characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 }) {
      return characters
    }
    return characters.isEmpty ? "Dead" : "Unidentified"
  }

  /// Key records for one key event's translated inputs. Text is sent as one `char` per typed
  /// character (not per UTF-16 unit), so surrogate pairs stay whole.
  /// - Parameters:
  ///   - inputs: The shared translator's output for the event.
  ///   - characters: The event's characters.
  /// - Returns: The records.
  public static func keys(_ inputs: [NativeKeyInput], characters: String) -> [KeyInput] {
    var result: [KeyInput] = []
    for input in inputs where input.kind != .char {
      let key = key(macKeyCode: input.nativeKeyCode, characters: characters)
      result.append(
        KeyInput(
          kind: input.kind == .keyUp ? .keyUp : .rawKeyDown, macKeyCode: input.nativeKeyCode,
          hidUsage: nil, code: nil, key: key, text: nil,
          modifiers: modifiers(input.modifiers).rawValue,
          repeat: input.modifiers.contains(.isRepeat)))
    }
    guard let down = inputs.first(where: { $0.kind == .rawKeyDown }),
      inputs.contains(where: { $0.kind == .char })
    else { return result }
    for character in characters
    where character.utf16.allSatisfy({ InputTranslator.insertsText($0) }) {
      let text = String(character)
      result.append(
        KeyInput(
          kind: .char, macKeyCode: down.nativeKeyCode, hidUsage: nil, code: nil,
          key: text == "\r" ? "Enter" : text, text: text,
          modifiers: modifiers(down.modifiers).rawValue,
          repeat: down.modifiers.contains(.isRepeat)))
    }
    return result
  }

  private static func kind(_ kind: PointerEventKind) -> MouseKind {
    switch kind {
    case .move: .move
    case .press: .down
    case .release: .up
    case .wheel: .wheel
    case .leave: .leave
    }
  }

  /// The held-button bit for a button.
  /// - Parameter button: The button.
  /// - Returns: Its bit.
  public static func buttonBit(_ button: MouseButton) -> RemoteModifiers {
    switch button {
    case .left: .leftButton
    case .middle: .middleButton
    case .right: .rightButton
    }
  }

  private static func buttonBit(_ button: PointerButton) -> RemoteModifiers {
    buttonBit(self.button(button))
  }

  private static func button(_ button: PointerButton) -> MouseButton {
    switch button {
    case .left: .left
    case .middle: .middle
    case .right: .right
    }
  }

  private static let namedHIDKeys: [UInt32: String] = [
    0x28: "Enter", 0x58: "Enter", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab",
    0x39: "CapsLock", 0x49: "Insert", 0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End",
    0x4E: "PageDown", 0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown", 0x52: "ArrowUp",
    0x65: "ContextMenu", 0xE0: "Control", 0xE1: "Shift", 0xE2: "Alt", 0xE3: "Meta",
    0xE4: "Control", 0xE5: "Shift", 0xE6: "Alt", 0xE7: "Meta",
  ]

  private static let namedMacKeys: [UInt16: String] = [
    36: "Enter", 76: "Enter", 48: "Tab", 51: "Backspace", 117: "Delete", 53: "Escape",
    123: "ArrowLeft", 124: "ArrowRight", 125: "ArrowDown", 126: "ArrowUp", 115: "Home",
    119: "End", 116: "PageUp", 121: "PageDown", 114: "Insert", 71: "Clear",
    56: "Shift", 60: "Shift", 59: "Control", 62: "Control", 58: "Alt", 61: "Alt", 55: "Meta",
    54: "Meta", 57: "CapsLock", 63: "Fn", 110: "ContextMenu",
    122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
    101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
    106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
  ]
}

extension RemoteBrowserCursor {
  /// The native shape for the page's CSS cursor keyword; unknown keywords show an arrow.
  nonisolated public var pageCursor: PageCursor {
    switch keyword {
    case "pointer": return .hand
    case "text", "vertical-text": return .iBeam
    case "crosshair", "cell": return .crosshair
    case "wait", "progress": return .wait
    case "help": return .help
    case "ew-resize", "col-resize", "e-resize", "w-resize": return .resizeLeftRight
    case "ns-resize", "row-resize", "n-resize", "s-resize": return .resizeUpDown
    case "not-allowed", "no-drop": return .notAllowed
    case "grab": return .grab
    case "grabbing": return .grabbing
    case "none": return .none
    default: return .pointer
    }
  }
}
