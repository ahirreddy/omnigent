internal import Foundation
internal import WebKit

/// Scripts the app runs in WebKit's content world of their own, apart from the page's scripts
/// and from the browser's bridge.
extension SystemBrowserTab {
  /// The world isolated scripts run in.
  static let isolatedWorld = WKContentWorld.world(name: "omnigent-design-tools")

  var evaluatesInIsolatedWorld: Bool { true }

  func evaluateIsolatedJavaScript(_ script: String) async throws(BrowserError)
    -> BrowserScriptValue
  {
    guard !state.isClosed else { throw .tabClosed }
    typealias Outcome = Result<BrowserScriptValue, BrowserError>
    let result: Outcome = await withCheckedContinuation { continuation in
      webView.evaluateJavaScript(script, in: nil, in: Self.isolatedWorld) { outcome in
        switch outcome {
        case .success(let value):
          continuation.resume(
            returning: Result { () throws(BrowserError) in
              try BrowserScriptValue(foundationObject: value)
            })
        case .failure(let error):
          continuation.resume(returning: .failure(Self.scriptError(error)))
        }
      }
    }
    return try result.get()
  }
}
