public import CoreGraphics

/// Modifier and button state, as CEF's `cef_event_flags_t` bits.
nonisolated public struct InputModifiers: OptionSet, Hashable, Sendable {
  /// The bits.
  public let rawValue: UInt64

  /// Creates modifiers from CEF bits.
  /// - Parameter rawValue: The bits.
  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  /// Caps Lock is on.
  public static let capsLock = Self(rawValue: 1 << 0)
  /// Shift.
  public static let shift = Self(rawValue: 1 << 1)
  /// Control.
  public static let control = Self(rawValue: 1 << 2)
  /// Option.
  public static let alt = Self(rawValue: 1 << 3)
  /// The left button is down.
  public static let leftMouse = Self(rawValue: 1 << 4)
  /// The middle button is down.
  public static let middleMouse = Self(rawValue: 1 << 5)
  /// The right button is down.
  public static let rightMouse = Self(rawValue: 1 << 6)
  /// Command.
  public static let command = Self(rawValue: 1 << 7)
  /// The key is on the numeric keypad.
  public static let isKeyPad = Self(rawValue: 1 << 9)
  /// The key is auto-repeating.
  public static let isRepeat = Self(rawValue: 1 << 13)
}

/// What a pointer event does. Raw values match the OWL wire protocol.
nonisolated public enum PointerEventKind: UInt64, Hashable, Sendable {
  /// The pointer moved (or dragged).
  case move = 1
  /// A button went down.
  case press = 2
  /// A button went up.
  case release = 3
  /// A scroll wheel or trackpad scroll.
  case wheel = 4
  /// The pointer left the view.
  case leave = 5
}

/// A mouse button. Raw values match `cef_mouse_button_type_t`.
nonisolated public enum PointerButton: UInt64, Hashable, Sendable {
  /// Primary.
  case left = 0
  /// Middle.
  case middle = 1
  /// Secondary.
  case right = 2
}

/// A key event's kind. Raw values match `cef_key_event_type_t`.
nonisolated public enum KeyEventKind: UInt64, Hashable, Sendable {
  /// Key down, before text insertion.
  case rawKeyDown = 0
  /// Key down with text (unused on macOS, where text arrives as `char`).
  case keyDown = 1
  /// Key up.
  case keyUp = 2
  /// One inserted UTF-16 unit.
  case char = 3
}

/// A pointer event in view coordinates (points, top-left origin).
nonisolated public struct PointerInput: Equatable, Sendable {
  /// What happened.
  public var kind: PointerEventKind
  /// View coordinates in points, top-left origin.
  public var location: CGPoint
  /// The button, for down and up.
  public var button: PointerButton
  /// Consecutive clicks, for down and up.
  public var clickCount: Int
  /// Modifiers and held buttons.
  public var modifiers: InputModifiers
  /// Horizontal scroll in points; positive scrolls left (content moves right).
  public var deltaX: Double
  /// Vertical scroll in points; positive scrolls up (content moves down).
  public var deltaY: Double

  /// Creates an event.
  /// - Parameters:
  ///   - kind: Kind.
  ///   - location: View point.
  ///   - button: Button.
  ///   - clickCount: Clicks.
  ///   - modifiers: Modifiers.
  ///   - deltaX: Horizontal scroll.
  ///   - deltaY: Vertical scroll.
  public init(
    kind: PointerEventKind, location: CGPoint, button: PointerButton = .left, clickCount: Int = 1,
    modifiers: InputModifiers = [], deltaX: Double = 0, deltaY: Double = 0
  ) {
    self.kind = kind
    self.location = location
    self.button = button
    self.clickCount = clickCount
    self.modifiers = modifiers
    self.deltaX = deltaX
    self.deltaY = deltaY
  }
}

/// A key event as CEF expects it on macOS: the native key code plus UTF-16 characters.
nonisolated public struct NativeKeyInput: Equatable, Sendable {
  /// What happened.
  public var kind: KeyEventKind
  /// The macOS virtual key code (`kVK_*`).
  public var nativeKeyCode: UInt16
  /// Modifiers.
  public var modifiers: InputModifiers
  /// The first UTF-16 unit the key produced, or the inserted unit for `char`.
  public var character: UInt16
  /// The first UTF-16 unit without modifiers.
  public var unmodifiedCharacter: UInt16

  /// Creates an event.
  /// - Parameters:
  ///   - kind: Kind.
  ///   - nativeKeyCode: Virtual key code.
  ///   - modifiers: Modifiers.
  ///   - character: Character unit.
  ///   - unmodifiedCharacter: Unmodified character unit.
  public init(
    kind: KeyEventKind, nativeKeyCode: UInt16, modifiers: InputModifiers = [],
    character: UInt16 = 0, unmodifiedCharacter: UInt16 = 0
  ) {
    self.kind = kind
    self.nativeKeyCode = nativeKeyCode
    self.modifiers = modifiers
    self.character = character
    self.unmodifiedCharacter = unmodifiedCharacter
  }
}

/// The pointer shape a page asks for. Mirrors the OWL cursor set.
nonisolated public enum PageCursor: String, Hashable, Sendable, CaseIterable {
  /// Arrow.
  case pointer
  /// Pointing hand.
  case hand
  /// Text I-beam.
  case iBeam
  /// Crosshair.
  case crosshair
  /// Busy; shown as an arrow.
  case wait
  /// Help.
  case help
  /// Horizontal resize.
  case resizeLeftRight
  /// Vertical resize.
  case resizeUpDown
  /// Not allowed.
  case notAllowed
  /// Open hand.
  case grab
  /// Closed hand.
  case grabbing
  /// Hidden.
  case none
}
