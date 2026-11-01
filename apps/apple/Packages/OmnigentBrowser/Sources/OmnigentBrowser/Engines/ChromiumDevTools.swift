package import Foundation

/// Parsers for Chrome DevTools Protocol results. Engine-independent so they are unit-testable;
/// `package` so the Chromium engine target can use them.
nonisolated package enum ChromiumDevTools {
  /// net::ERR_ABORTED, reported when a navigation is stopped or superseded.
  package static let netErrorAborted = -3

  package static func evaluateResult(json: String) throws(BrowserError) -> BrowserScriptValue {
    let root = try object(json, method: "Runtime.evaluate")
    if let details = root["exceptionDetails"] as? [String: Any] {
      let exception = details["exception"] as? [String: Any]
      let message =
        exception?["description"] as? String ?? details["text"] as? String
        ?? "Uncaught exception"
      throw .scriptFailed(message: message)
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
    guard result.keys.contains("value") else {
      let type = result["className"] as? String ?? result["type"] as? String ?? "unknown"
      throw .unsupportedScriptResult(type)
    }
    return try BrowserScriptValue(foundationObject: result["value"])
  }

  package static func screenshotData(json: String) throws(BrowserError) -> Data {
    let root = try object(json, method: "Page.captureScreenshot")
    guard let base64 = root["data"] as? String, let data = Data(base64Encoded: base64) else {
      throw .snapshotFailed("Page.captureScreenshot returned no image data.")
    }
    return data
  }

  private static func object(_ json: String, method: String) throws(BrowserError)
    -> [String: Any]
  {
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
    } catch {
      throw .devToolsFailed(method: method, message: "Invalid JSON: \(error.localizedDescription)")
    }
    guard let object = parsed as? [String: Any] else {
      throw .devToolsFailed(method: method, message: "Expected a JSON object: \(json)")
    }
    return object
  }
}
