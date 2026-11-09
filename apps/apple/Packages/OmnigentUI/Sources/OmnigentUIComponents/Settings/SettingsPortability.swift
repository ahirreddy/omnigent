public import Foundation

/// Export, import and reset of device-local preferences, in the web's settings file format
/// (`web/src/lib/settingsPortability.ts`): `{"version": 1, "settings": {key: text}}` over the
/// web's keys, so a file moves between the Mac app and the web unchanged.
nonisolated public enum SettingsPortability {
  /// The web's exportable `localStorage` keys; a file with any other key is rejected, as on the
  /// web.
  public static let exportableKeys: [String] = [
    "omnigent:ui-font-size", "omnigent:ui-font-family", "omnigent:code-font-size",
    "omnigent:code-font-family", "omnigent:code-font-weight", "omnigent:terminal-theme",
    "omnigent:ui-theme-palette", "omnigent:custom-theme", "omnigent:default-workspace-panel",
    "omnigent:default-workspace-tab", "omnigent:pinned-workspace-tabs",
    "omnigent:default-transcript-view", "omnigent:hide-unconfigured-harnesses",
    "omnigent:fold-assistant-narration", "omnigent:hidden-picker-agents",
    "omnigent:default-base-branch", "omnigent:always-use-worktree",
    "omnigent:delete-worktrees-on-archive", "omnigent:composer-submit-with-mod-enter",
    "web-theme",
  ]

  /// The appearance keys "Reset to defaults" clears, as the web's Appearance reset.
  public static let appearanceKeys: [String] = [
    "omnigent:ui-font-size", "omnigent:ui-font-family", "omnigent:code-font-size",
    "omnigent:code-font-family", "omnigent:code-font-weight", "omnigent:terminal-theme",
    "omnigent:ui-theme-palette", "omnigent:custom-theme", "omnigent:default-transcript-view",
    "omnigent:default-workspace-panel", "omnigent:default-workspace-tab",
    "omnigent:pinned-workspace-tabs", "omnigent:hide-unconfigured-harnesses",
    "omnigent:fold-assistant-narration", "omnigent:hidden-picker-agents", "web-theme",
  ]

  /// Keys whose `"true"`/`"false"` text is kept as text (a tri-state the app stores as text);
  /// every other `"true"`/`"false"` value is stored as a Boolean.
  static let textBooleanKeys: Set<String> = ["omnigent:delete-worktrees-on-archive"]

  /// The file's version.
  static let version = 1

  /// The suggested file name.
  public static let fileName = "omnigent-settings.json"

  /// Why a settings file was not imported.
  public enum ImportError: Error, Equatable, CustomStringConvertible {
    /// Not JSON.
    case invalidJSON
    /// JSON, but not an Omnigent settings file.
    case notSettings

    /// The message the web shows.
    public var description: String {
      switch self {
      case .invalidJSON: "The file contains invalid JSON."
      case .notSettings: "The file doesn't contain valid Omnigent settings."
      }
    }
  }

  /// The stored preferences as a settings file, defaults included only when set.
  /// - Parameter defaults: Where the preferences live.
  /// - Returns: The file's JSON.
  /// - Throws: An encoding error (not expected for text values).
  public static func export(_ defaults: UserDefaults = .standard) throws -> Data {
    var settings: [String: String] = [:]
    for key in exportableKeys {
      if let value = text(defaults.object(forKey: key)) { settings[key] = value }
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(File(version: version, settings: settings))
  }

  /// Reads and validates a settings file.
  /// - Parameter data: The file.
  /// - Returns: Its settings.
  /// - Throws: ``ImportError``.
  public static func settings(in data: Data) throws(ImportError) -> [String: String] {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw .invalidJSON
    }
    // Any JSON number from 1 up, as on the web; `true` also bridges to a number but isn't one.
    guard let file = object as? [String: Any], let rawVersion = file["version"],
      !isBoolean(rawVersion), let version = rawVersion as? Double, version >= 1,
      let settings = file["settings"] as? [String: Any]
    else { throw .notSettings }
    let allowed = Set(exportableKeys)
    var values: [String: String] = [:]
    for (key, value) in settings {
      guard allowed.contains(key), let text = value as? String else { throw .notSettings }
      values[key] = text
    }
    return values
  }

  /// Replaces every exportable preference with `settings` (keys it omits return to their
  /// defaults), as the web's import. A key the app stores as a number keeps a number.
  /// - Parameters:
  ///   - settings: Validated settings (``settings(in:)``).
  ///   - defaults: Where the preferences live.
  /// - Returns: How many values were written.
  @discardableResult
  public static func apply(_ settings: [String: String], to defaults: UserDefaults = .standard)
    -> Int
  {
    let numericKeys = Set(
      exportableKeys.filter { key in
        guard let stored = defaults.object(forKey: key), stored is Double else { return false }
        return !isBoolean(stored)
      })
    for key in exportableKeys where settings[key] == nil {
      defaults.removeObject(forKey: key)
    }
    var count = 0
    for key in exportableKeys {
      guard let value = settings[key] else { continue }
      if !textBooleanKeys.contains(key), let flag = Bool(value) {
        defaults.set(flag, forKey: key)
      } else if numericKeys.contains(key), let number = Double(value) {
        defaults.set(number, forKey: key)
      } else {
        defaults.set(value, forKey: key)
      }
      count += 1
    }
    return count
  }

  /// Clears the appearance preferences, as the web's "Reset to defaults".
  /// - Parameter defaults: Where the preferences live.
  public static func resetAppearance(_ defaults: UserDefaults = .standard) {
    for key in appearanceKeys where defaults.object(forKey: key) != nil {
      defaults.removeObject(forKey: key)
    }
  }

  /// A stored value as the web's text: Booleans as `true`/`false`, numbers in decimal.
  static func text(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let text = value as? String { return text }
    if isBoolean(value), let flag = value as? Bool { return flag ? "true" : "false" }
    guard let number = value as? Double else { return nil }
    return number.rounded() == number && abs(number) < 1e15
      ? String(Int64(number)) : String(number)
  }

  /// A stored number that is a Boolean (`UserDefaults` bridges both to one number type).
  private static func isBoolean(_ value: Any) -> Bool {
    CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
  }

  private struct File: Encodable {
    let version: Int
    let settings: [String: String]
  }
}
