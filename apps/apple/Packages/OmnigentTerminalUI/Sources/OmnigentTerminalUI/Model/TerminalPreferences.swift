public import Foundation

/// The terminal's light or dark choice: the web's `omnigent:terminal-theme` (`auto` follows the
/// app's appearance; `light` and `dark` pin it).
public enum TerminalThemeMode: String, Hashable, Sendable, CaseIterable {
  /// Follow the app.
  case auto
  /// Always light.
  case light
  /// Always dark.
  case dark

  /// The device-local key, shared with Settings › Appearance.
  public static let key = "omnigent:terminal-theme"

  /// The stored mode; anything the web would not write is `auto`, as on the web.
  /// - Parameter stored: The stored text.
  public init(stored: String?) {
    self = stored.flatMap(Self.init(rawValue:)) ?? .auto
  }

  /// The palette for the app's current appearance.
  /// - Parameter app: The app's light or dark mode.
  /// - Returns: The terminal's.
  public func resolved(app: TerminalColorScheme) -> TerminalColorScheme {
    switch self {
    case .auto: app
    case .light: .light
    case .dark: .dark
    }
  }
}

/// The terminal settings kept across launches: font, scrollback, Option as Alt and cursor
/// blink. Colors are not stored here; they follow ``TerminalThemeMode``.
public enum TerminalPreferences {
  /// Font size in points.
  public static let fontSizeKey = "omnigent.terminal.fontSize"
  /// Font family; absent for the system monospaced font.
  public static let fontFamilyKey = "omnigent.terminal.fontFamily"
  /// Scrollback, a ``TerminalScrollback`` raw value.
  public static let scrollbackKey = "omnigent.terminal.scrollback"
  /// Option sends Alt (macOS).
  public static let optionAsAltKey = "omnigent.terminal.optionAsAlt"
  /// Blinking cursor.
  public static let cursorBlinkKey = "omnigent.terminal.cursorBlink"

  /// The font sizes Settings offers.
  public static let fontSizes: ClosedRange<Double> = 8...32

  /// `base` with the stored settings and terminal theme applied; a stored value out of range is
  /// ignored.
  /// - Parameters:
  ///   - base: The system appearance.
  ///   - defaults: Where the settings live.
  /// - Returns: The appearance.
  public static func load(
    over base: TerminalAppearance, defaults: UserDefaults = .standard
  ) -> TerminalAppearance {
    var appearance = base
    if let size = defaults.object(forKey: fontSizeKey) as? Double, fontSizes.contains(size) {
      appearance.fontSize = size
    }
    if let family = defaults.string(forKey: fontFamilyKey), !family.isEmpty {
      appearance.fontFamily = family
    }
    if let raw = defaults.object(forKey: scrollbackKey) as? Int,
      let scrollback = TerminalScrollback(rawValue: raw)
    {
      appearance.scrollback = scrollback
    }
    if let optionAsAlt = defaults.object(forKey: optionAsAltKey) as? Bool {
      appearance.optionAsAlt = optionAsAlt
    }
    if let cursorBlink = defaults.object(forKey: cursorBlinkKey) as? Bool {
      appearance.cursorBlink = cursorBlink
    }
    let mode = TerminalThemeMode(stored: defaults.string(forKey: TerminalThemeMode.key))
    appearance.colorScheme = mode.resolved(app: base.colorScheme)
    return appearance
  }

  /// Stores the settings of `appearance` that differ from what is stored.
  /// - Parameters:
  ///   - appearance: The appearance.
  ///   - defaults: Where the settings live.
  public static func save(_ appearance: TerminalAppearance, defaults: UserDefaults = .standard) {
    store(appearance.fontSize, fontSizeKey, defaults)
    if let family = appearance.fontFamily {
      store(family, fontFamilyKey, defaults)
    } else if defaults.object(forKey: fontFamilyKey) != nil {
      defaults.removeObject(forKey: fontFamilyKey)
    }
    store(appearance.scrollback.rawValue, scrollbackKey, defaults)
    store(appearance.optionAsAlt, optionAsAltKey, defaults)
    store(appearance.cursorBlink, cursorBlinkKey, defaults)
  }

  private static func store<Value: Equatable>(
    _ value: Value, _ key: String, _ defaults: UserDefaults
  ) {
    if defaults.object(forKey: key) as? Value != value { defaults.set(value, forKey: key) }
  }

  /// `current` with the settings `edited` changes; colors stay `current`'s, which follow the
  /// app and the terminal theme rather than this screen.
  /// - Parameters:
  ///   - edited: The settings screen's appearance.
  ///   - current: The runtime's appearance.
  /// - Returns: The appearance to apply.
  public static func merge(_ edited: TerminalAppearance, into current: TerminalAppearance)
    -> TerminalAppearance
  {
    var next = edited
    next.colorScheme = current.colorScheme
    return next
  }
}
