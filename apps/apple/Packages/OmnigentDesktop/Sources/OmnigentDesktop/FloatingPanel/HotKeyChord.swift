public import AppKit

/// A key and the modifiers held with it, as a system-wide shortcut records it.
nonisolated public struct HotKeyChord: Hashable, Sendable, Codable {
  /// The modifiers, in the menu bar's order.
  nonisolated public struct Modifiers: OptionSet, Hashable, Sendable, Codable {
    /// The bits.
    public let rawValue: Int

    /// Creates modifiers from their bits.
    /// - Parameter rawValue: The bits.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Control (⌃).
    public static let control = Self(rawValue: 1 << 0)
    /// Option (⌥).
    public static let option = Self(rawValue: 1 << 1)
    /// Shift (⇧).
    public static let shift = Self(rawValue: 1 << 2)
    /// Command (⌘).
    public static let command = Self(rawValue: 1 << 3)
  }

  /// The virtual key code.
  public let keyCode: UInt16
  /// The modifiers held.
  public let modifiers: Modifiers
  /// The key's name as Settings shows it ("Space", "K").
  public let keyName: String

  /// Space with Shift and Command, the New Agent panel's default, as on the desktop app.
  public static let newAgentPanelDefault = Self(
    keyCode: 49, modifiers: [.shift, .command], keyName: "Space")

  /// Creates a chord.
  /// - Parameters:
  ///   - keyCode: The virtual key code.
  ///   - modifiers: The modifiers.
  ///   - keyName: The key's name.
  public init(keyCode: UInt16, modifiers: Modifiers, keyName: String) {
    self.keyCode = keyCode
    self.modifiers = modifiers
    self.keyName = keyName
  }

  /// The chord a key press records, or `nil` when it holds none of Command, Control and
  /// Option: a system-wide shortcut without one would take ordinary typing from every app.
  /// - Parameters:
  ///   - keyCode: The key's virtual key code.
  ///   - flags: The modifiers held.
  ///   - characters: The key's characters without modifiers.
  public init?(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
    var modifiers: Modifiers = []
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    guard !modifiers.isDisjoint(with: [.command, .control, .option]),
      let name = Self.keyName(keyCode: keyCode, characters: characters)
    else { return nil }
    self.init(keyCode: keyCode, modifiers: modifiers, keyName: name)
  }

  /// The chord as the menu bar writes one: "⇧⌘Space".
  public var displayText: String {
    let symbols: [(Modifiers, String)] = [
      (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
    ]
    return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
  }

  /// Keys whose characters don't name them.
  private static let namedKeys: [UInt16: String] = [
    49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 117: "Forward Delete", 53: "Esc",
    123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up",
    121: "Page Down", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
    100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
  ]

  /// A key's name: its own for keys like Space, else its character upper-cased.
  static func keyName(keyCode: UInt16, characters: String?) -> String? {
    if let name = namedKeys[keyCode] { return name }
    guard let characters, characters.count == 1,
      characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return characters.uppercased()
  }
}
