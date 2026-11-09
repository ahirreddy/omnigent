public import Foundation

/// The terminal a new terminal starts as when none is named: the last one chosen while the
/// session declares it, else the session's first declared terminal (a native harness lists its
/// host's `$SHELL` first). One choice for every session, since the names are shells such as zsh,
/// bash and fish, under the web's key.
nonisolated public enum PreferredTerminal {
  /// The `UserDefaults` key, the web's `omnigent:preferred-shell`.
  public static let key = "omnigent:preferred-shell"

  /// The terminal to start among a session's declared ones.
  /// - Parameters:
  ///   - declared: The declared names, in declaration order.
  ///   - preferred: The remembered choice.
  /// - Returns: `preferred` when the session declares it, else the first name; `nil` for none.
  public static func resolve(_ declared: [String], preferred: String?) -> String? {
    if let preferred, declared.contains(preferred) { return preferred }
    return declared.first
  }

  /// The remembered choice.
  /// - Parameter defaults: The store.
  /// - Returns: The name, or `nil` when none was chosen.
  public static func stored(in defaults: UserDefaults = .standard) -> String? {
    defaults.string(forKey: key)
  }
}
