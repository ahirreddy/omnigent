internal import Foundation

/// A JavaScript value returned from evaluation.
nonisolated public enum WebScriptValue: Hashable, Sendable {
  /// `undefined`.
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

  /// The string payload, if this is a string.
  public var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  /// Converts a `JSONSerialization` object graph.
  init(json object: Any) throws(WebLayerError) {
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
      self = .array(try array.map { element throws(WebLayerError) in try Self(json: element) })
    case let dictionary as [String: Any]:
      var values: [String: Self] = [:]
      for (key, element) in dictionary {
        values[key] = try Self(json: element)
      }
      self = .object(values)
    default:
      throw .unsupportedScriptResult(String(describing: type(of: object)))
    }
  }

  /// Parses a Chrome DevTools Protocol `Runtime.evaluate` result.
  /// - Throws: `.scriptFailed` for exceptions, `.devToolsFailed` for malformed results, and
  ///   `.unsupportedScriptResult` for values that cannot be returned by value.
  static func fromEvaluateResult(json: String) throws(WebLayerError) -> Self {
    let root = try DevToolsJSON.object(json, method: "Runtime.evaluate")
    if let details = root["exceptionDetails"] as? [String: Any] {
      let exception = details["exception"] as? [String: Any]
      throw .scriptFailed(
        exception?["description"] as? String ?? details["text"] as? String
          ?? "Uncaught exception")
    }
    guard let result = root["result"] as? [String: Any] else {
      throw .devToolsFailed(method: "Runtime.evaluate", message: "Missing result: \(json)")
    }
    if let unserializable = result["unserializableValue"] as? String {
      switch unserializable {
      case "NaN": return .number(.nan)
      case "Infinity": return .number(.infinity)
      case "-Infinity": return .number(-.infinity)
      case "-0": return .number(-0.0)
      default: return .string(unserializable)
      }
    }
    if result["type"] as? String == "undefined" {
      return .undefined
    }
    guard let value = result["value"] else {
      throw .unsupportedScriptResult(
        result["className"] as? String ?? result["type"] as? String ?? "unknown")
    }
    return try Self(json: value)
  }
}

/// JSON helpers for DevTools Protocol replies.
nonisolated enum DevToolsJSON {
  static func object(_ json: String, method: String) throws(WebLayerError) -> [String: Any] {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    } catch {
      throw .devToolsFailed(method: method, message: "Invalid JSON: \(error.localizedDescription)")
    }
    guard let object = parsed as? [String: Any] else {
      throw .devToolsFailed(method: method, message: "Expected a JSON object: \(json)")
    }
    return object
  }

  /// The error message of a failed call, as CEF reports it. Text that is not a JSON object with
  /// a `message` is returned whole, so nothing is lost.
  static func failureMessage(_ json: String) -> String {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
      let message = (object as? [String: Any])?["message"] as? String
    else {
      return json
    }
    return message
  }
}
