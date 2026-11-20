internal import Foundation

/// Scripts in a world of their own: an isolated world DevTools makes for the main frame's
/// document, where the page's scripts can neither see their globals nor change the built-ins
/// they call, as WebKit's content worlds.
extension WebView {
  /// Evaluates `script` in the main frame in the isolated world `worldName` and returns its
  /// completion value. Promises are not awaited. The world is made for a document on first use;
  /// a navigation retires it with its document, and the next call makes the new document's.
  public func evaluateIsolatedJavaScript(_ script: String, worldName: String)
    async throws(WebLayerError) -> WebScriptValue
  {
    if let context = isolatedContexts[worldName] {
      do {
        return try await evaluate(script, inContext: context)
      } catch WebLayerError.devToolsFailed {
        // DevTools no longer finds the context: its document went, so make the new one's.
        if isolatedContexts[worldName] == context { isolatedContexts[worldName] = nil }
      }
    }
    let context = try await makeIsolatedWorld(worldName)
    isolatedContexts[worldName] = context
    return try await evaluate(script, inContext: context)
  }

  private struct IsolatedWorldParams: Encodable {
    let frameId: String
    let worldName: String
    // DevTools' own spelling.
    let grantUniveralAccess = false
  }

  private struct EvaluateParams: Encodable {
    let expression: String
    let contextId: Int
    let returnByValue = true
  }

  /// A new isolated world in the main frame's current document; its execution context id.
  private func makeIsolatedWorld(_ worldName: String) async throws(WebLayerError) -> Int {
    let treeMethod = "Page.getFrameTree"
    let tree = try DevToolsJSON.object(try await callDevToolsMethod(treeMethod), method: treeMethod)
    guard let frameTree = tree["frameTree"] as? [String: Any],
      let frame = frameTree["frame"] as? [String: Any], let frameID = frame["id"] as? String
    else { throw .devToolsFailed(method: treeMethod, message: "The page has no main frame.") }
    let worldMethod = "Page.createIsolatedWorld"
    let params = try Self.json(IsolatedWorldParams(frameId: frameID, worldName: worldName))
    let reply = try DevToolsJSON.object(
      try await callDevToolsMethod(worldMethod, paramsJSON: params), method: worldMethod)
    guard let context = reply["executionContextId"] as? Int else {
      throw .devToolsFailed(method: worldMethod, message: "No execution context was made.")
    }
    return context
  }

  private func evaluate(_ script: String, inContext context: Int)
    async throws(WebLayerError) -> WebScriptValue
  {
    let params = try Self.json(EvaluateParams(expression: script, contextId: context))
    let json = try await callDevToolsMethod("Runtime.evaluate", paramsJSON: params)
    return try WebScriptValue.fromEvaluateResult(json: json)
  }

  private static func json(_ value: some Encodable) throws(WebLayerError) -> String {
    let data: Data
    do {
      data = try JSONEncoder().encode(value)
    } catch {
      throw .invalidArgument(
        "DevTools parameters couldn't be encoded: \(error.localizedDescription)")
    }
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw .invalidArgument("DevTools parameters weren't UTF-8.")
    }
    return text
  }
}
