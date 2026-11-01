import Foundation
import OmnigentGhosttyKit

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Keys the on-screen accessory row and commands send through Ghostty's key encoder.
public enum TerminalKey: String, CaseIterable, Sendable, Identifiable {
  case escape, tab, enter, backspace, delete
  case arrowUp, arrowDown, arrowLeft, arrowRight
  case home, end, pageUp, pageDown
  case character

  /// The stable identity.
  public var id: String { rawValue }

  /// The macOS virtual keycode, which libghostty uses as the native keycode on macOS and iOS.
  var macKeyCode: UInt32 {
    switch self {
    case .escape: 0x35
    case .tab: 0x30
    case .enter: 0x24
    case .backspace: 0x33
    case .delete: 0x75
    case .arrowUp: 0x7E
    case .arrowDown: 0x7D
    case .arrowLeft: 0x7B
    case .arrowRight: 0x7C
    case .home: 0x73
    case .end: 0x77
    case .pageUp: 0x74
    case .pageDown: 0x79
    case .character: 0
    }
  }

  var unshiftedCodepoint: UInt32 {
    switch self {
    case .escape: 0x1B
    case .tab: 0x09
    case .enter: 0x0D
    case .backspace: 0x7F
    default: 0
    }
  }
}

/// Modifier keys.
public struct TerminalModifiers: OptionSet, Hashable, Sendable {
  /// The raw bits.
  public let rawValue: UInt32
  /// See the protocol requirement.
  public init(rawValue: UInt32) { self.rawValue = rawValue }

  /// Shift.
  public static let shift = Self(rawValue: 1 << 0)
  /// Control.
  public static let control = Self(rawValue: 1 << 1)
  /// Option / Alt.
  public static let option = Self(rawValue: 1 << 2)
  /// Command / Super.
  public static let command = Self(rawValue: 1 << 3)

  var ghostty: ghostty_input_mods_e {
    ghostty_input_mods_e(rawValue: rawValue)
  }
}

/// The system clipboard.
enum TerminalPasteboard {
  static func read() -> String? {
    #if os(macOS)
      NSPasteboard.general.string(forType: .string)
    #else
      UIPasteboard.general.string
    #endif
  }

  static func write(_ text: String) {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
    #endif
  }
}

/// Opens links the terminal detected. Only web and mail links open; a remote program must not
/// be able to launch local apps through custom URL schemes or `file:` URLs.
enum TerminalLinks {
  static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

  @discardableResult
  static func open(_ text: String) -> Bool {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
      allowedSchemes.contains(scheme)
    else { return false }
    #if os(macOS)
      return NSWorkspace.shared.open(url)
    #else
      UIApplication.shared.open(url)
      return true
    #endif
  }
}

/// Decodes terminal bytes as UTF-8, replacing invalid sequences with U+FFFD. Terminal text
/// (titles, screen contents) is not guaranteed to be valid UTF-8, and showing a replacement
/// character is the intended behavior rather than dropping the whole string.
func lossyUTF8(_ bytes: some Sequence<UInt8>) -> String {
  // swiftlint:disable:next optional_data_string_conversion
  String(decoding: Array(bytes), as: UTF8.self)
}
