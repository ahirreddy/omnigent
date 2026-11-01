import Foundation
import OSLog
public import OmnigentCoreFFI

/// Why a managed preference value could not be converted to JSON text.
public enum ManagedPreferenceError: Error, Sendable, Equatable {
  /// The value is not a property-list type.
  case unsupportedType(String)
  /// The value is a number that JSON cannot represent (NaN or infinity).
  case nonFiniteNumber
}

/// `ManagedPreferenceSource` host implementation over `CFPreferences`.
///
/// Values are read from the given domain and converted to JSON text: property-list booleans
/// become JSON booleans (never numbers), dates become ISO 8601 strings and data becomes base64
/// text, as the core's contract requires.
public final class ManagedPreferencesSource: ManagedPreferenceSource, Sendable {
  private let reader: @Sendable (_ key: String, _ domain: String) -> Any?
  private let forced: @Sendable (_ key: String, _ domain: String) -> Bool

  /// Creates a source that reads the system's preference domains.
  public convenience init() {
    self.init(
      reader: { key, domain in
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
      },
      forced: { key, domain in
        CFPreferencesAppValueIsForced(key as CFString, domain as CFString)
      })
  }

  /// Creates a source over injected readers. Tests use this to supply a dictionary instead of
  /// real managed preferences.
  /// - Parameters:
  ///   - reader: Returns the property-list value of a key in a domain, or nil.
  ///   - forced: Whether an administrator forces the key in the domain.
  public init(
    reader: @escaping @Sendable (_ key: String, _ domain: String) -> Any?,
    forced: @escaping @Sendable (_ key: String, _ domain: String) -> Bool
  ) {
    self.reader = reader
    self.forced = forced
  }

  /// The JSON text of `key` in `domain`. A value that cannot be converted is logged and
  /// reported as absent, because the core's contract has no error channel here.
  public func value(key: String, domain: String) -> String? {
    guard let raw = reader(key, domain) else { return nil }
    do {
      return try Self.jsonText(for: raw)
    } catch {
      servicesLogger.error(
        "Managed preference \(key) in \(domain) is not convertible to JSON: \(String(describing: error))"
      )
      return nil
    }
  }

  /// Whether an administrator forces `key` in `domain`.
  public func isForced(key: String, domain: String) -> Bool {
    forced(key, domain)
  }

  /// Converts a property-list value to JSON text.
  /// - Parameter value: A `String`, `NSNumber` (including booleans), `Date`, `Data`, or an array
  ///   or string-keyed dictionary of those.
  /// - Returns: The JSON text.
  /// - Throws: `ManagedPreferenceError` for any other type or a non-finite number.
  public static func jsonText(for value: Any) throws(ManagedPreferenceError) -> String {
    let jsonObject = try jsonObject(for: value)
    let options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: jsonObject, options: options)
    } catch {
      throw .unsupportedType(String(describing: error))
    }
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw .unsupportedType("JSON encoding was not UTF-8")
    }
    return text
  }

  /// The JSON-compatible tree for a property-list value.
  private static func jsonObject(for value: Any) throws(ManagedPreferenceError) -> Any {
    if let array = value as? [Any] {
      var converted: [Any] = []
      for element in array {
        converted.append(try jsonObject(for: element))
      }
      return converted
    }
    if let dictionary = value as? [String: Any] {
      var converted: [String: Any] = [:]
      for (key, element) in dictionary {
        converted[key] = try jsonObject(for: element)
      }
      return converted
    }
    return try scalarJSONObject(for: value)
  }

  /// The JSON-compatible value of a scalar property-list value.
  private static func scalarJSONObject(for value: Any) throws(ManagedPreferenceError) -> Any {
    switch value {
    case let string as String:
      return string
    // swiftlint:disable:next legacy_objc_type
    case let number as NSNumber:
      return try numberJSONObject(number)
    case let date as Date:
      return date.formatted(.iso8601)
    case let data as Data:
      return data.base64EncodedString()
    default:
      throw .unsupportedType(String(describing: type(of: value)))
    }
  }

  // NSNumber is the property-list number type, and a CFBoolean bridges to it too.
  // swiftlint:disable legacy_objc_type
  /// A boolean stays a boolean; any other number must be finite.
  private static func numberJSONObject(_ number: NSNumber) throws(ManagedPreferenceError) -> Any {
    // Check the CFBoolean type so that 1 is never read as true.
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      return number.boolValue
    }
    guard number.doubleValue.isFinite else { throw .nonFiniteNumber }
    return number
  }
  // swiftlint:enable legacy_objc_type
}
