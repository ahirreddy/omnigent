public import Foundation

/// What happens when a terminal program copies text to the clipboard (tmux copy mode, OSC 52):
/// ask each time, allow, or block. Settings > Terminal sets it for every terminal on this Mac.
public enum TerminalClipboardPolicy: String, CaseIterable, Identifiable, Sendable {
  /// Show the consent banner.
  case ask
  /// Copy without asking.
  case allow
  /// Never copy.
  case block

  /// The `UserDefaults` key.
  public static let key = "omnigent:terminal-clipboard"

  /// The stored policy; ``ask`` when unset or unreadable.
  /// - Parameter defaults: The store.
  /// - Returns: The policy.
  public static func current(_ defaults: UserDefaults = .standard) -> Self {
    defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .ask
  }

  /// The policy itself.
  public var id: Self { self }

  /// The menu title.
  public var title: String {
    switch self {
    case .ask: "Ask before copying"
    case .allow: "Allow copying"
    case .block: "Block copying"
    }
  }
}
