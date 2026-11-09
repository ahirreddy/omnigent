public import Foundation
public import OmnigentCoreFFI

/// `SettingsStorage` host implementation over `UserDefaults`.
///
/// The core exchanges values as JSON text, but values are stored as native property-list
/// objects. A string stored as `"https://…"` is therefore the same value `@AppStorage` reads, so
/// settings written by the SwiftUI layer stay compatible. Dates and data have no JSON form and
/// are rejected, not converted.
public final class UserDefaultsSettingsStorage: SettingsStorage, Sendable {
  private let store: DefaultsBox

  /// Creates a storage over `defaults`.
  /// - Parameter defaults: The defaults database. Tests pass a suite they remove afterwards.
  public init(defaults: UserDefaults = .standard) {
    self.store = DefaultsBox(defaults: defaults)
  }

  private var defaults: UserDefaults { store.defaults }

  /// The stored value under `key`, as JSON text.
  /// - Parameter key: The settings key.
  /// - Returns: The JSON text, or nil when nothing is stored.
  /// - Throws: `SettingsStorageError.Failed` when the stored value has no JSON form.
  public func get(key: String) throws(SettingsStorageError) -> String? {
    guard let object = defaults.object(forKey: key) else { return nil }
    guard Self.isPropertyListJSONCompatible(object) else {
      throw .Failed(
        message: "Setting \(key) holds a \(type(of: object)) value, which has no JSON form")
    }
    do {
      let data = try JSONSerialization.data(
        withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes])
      // JSONSerialization always writes UTF-8.
      // swiftlint:disable:next optional_data_string_conversion
      return String(decoding: data, as: UTF8.self)
    } catch {
      throw .Failed(message: "Setting \(key) could not be encoded as JSON: \(error)")
    }
  }

  /// Stores `value` under `key`, parsing it as JSON. JSON `null` and nil both remove the key.
  /// - Parameters:
  ///   - key: The settings key.
  ///   - value: The JSON text, or nil to remove the key.
  /// - Throws: `SettingsStorageError.Failed` when `value` is not JSON or holds `null` inside a
  ///   container, which property lists cannot store.
  public func set(key: String, value: String?) throws(SettingsStorageError) {
    guard let value else {
      defaults.removeObject(forKey: key)
      return
    }
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(
        with: Data(value.utf8), options: .fragmentsAllowed)
    } catch {
      throw .Failed(message: "Setting \(key) is not valid JSON: \(error.localizedDescription)")
    }
    if parsed is NSNull {
      defaults.removeObject(forKey: key)
      return
    }
    guard Self.isPropertyListJSONCompatible(parsed) else {
      throw .Failed(
        message: "Setting \(key) holds JSON null inside a container, which cannot be stored")
    }
    defaults.set(parsed, forKey: key)
  }

  /// Whether `value` is a property-list object that `JSONSerialization` can encode. Checked
  /// before encoding: `JSONSerialization` raises an Objective-C exception on other types.
  static func isPropertyListJSONCompatible(_ value: Any) -> Bool {
    switch value {
    case is String:
      return true
    // NSNumber is the property-list number type, which Swift numeric types cannot stand in for.
    // swiftlint:disable:next legacy_objc_type
    case let number as NSNumber:
      // JSON has no NaN or infinity, and encoding one raises an exception too.
      return number.doubleValue.isFinite
    case let array as [Any]:
      return array.allSatisfy(isPropertyListJSONCompatible)
    case let dictionary as [String: Any]:
      return dictionary.values.allSatisfy(isPropertyListJSONCompatible)
    default:
      return false
    }
  }
}

/// Holds `UserDefaults` for use across isolation domains. The SDK does not mark `UserDefaults`
/// Sendable, but Apple documents it as thread-safe, and this box only ever makes single get, set
/// or remove calls on it.
private final class DefaultsBox: @unchecked Sendable {
  let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }
}
