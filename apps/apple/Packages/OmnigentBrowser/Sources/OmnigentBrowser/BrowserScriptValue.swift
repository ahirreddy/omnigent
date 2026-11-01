public import Foundation

/// A JavaScript value returned from script evaluation, normalized across engines.
nonisolated public enum BrowserScriptValue: Hashable, Sendable {
  /// `undefined`, including scripts whose completion value is empty.
  case undefined
  /// `null`.
  case null
  /// A boolean.
  case bool(Bool)
  /// A number. `NaN` and infinities are preserved.
  case number(Double)
  /// A string.
  case string(String)
  /// An array.
  case array([Self])
  /// A plain object.
  case object([String: Self])

  /// Converts a Foundation object graph (WebKit and `JSONSerialization` results).
  /// - Throws: `BrowserError.unsupportedScriptResult` for values with no JSON equivalent.
  public init(foundationObject: Any?) throws(BrowserError) {
    guard let object = foundationObject else {
      self = .undefined
      return
    }
    // Booleans and numbers both arrive as NSNumber; only the CFBoolean singletons are booleans.
    if CFGetTypeID(object as CFTypeRef) == CFBooleanGetTypeID(), let bool = object as? Bool {
      self = .bool(bool)
      return
    }
    switch object {
    case is NSNull:
      self = .null
    case let string as String:
      self = .string(string)
    case let number as Double:
      self = .number(number)
    case let integer as Int:
      self = .number(Double(integer))
    case let array as [Any]:
      self = .array(
        try array.map { element throws(BrowserError) in try Self(foundationObject: element) })
    case let dictionary as [String: Any]:
      self = .object(try Self.convert(dictionary))
    case let date as Date:
      self = .number(date.timeIntervalSince1970 * 1000)
    default:
      throw .unsupportedScriptResult(String(describing: type(of: object)))
    }
  }

  private static func convert(_ dictionary: [String: Any]) throws(BrowserError) -> [String: Self] {
    var values: [String: Self] = [:]
    for (key, element) in dictionary {
      values[key] = try Self(foundationObject: element)
    }
    return values
  }

  /// Parses a JSON document.
  /// - Throws: `BrowserError.scriptFailed` when the data is not valid JSON.
  public init(jsonData: Data) throws(BrowserError) {
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
    } catch {
      throw .scriptFailed(message: "Invalid JSON result: \(error.localizedDescription)")
    }
    try self.init(foundationObject: object)
  }

  /// The string payload, if this is a string.
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// The number payload, if this is a number.
  public var numberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }
}
